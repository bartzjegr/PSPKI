function Add-CertificateEnrollmentService {
<#
.ExternalHelp PSPKI.Help.xml
#>
[OutputType('SysadminsLV.PKI.Utils.IServiceOperationResult')]
[CmdletBinding()]
	param(
		[string]$CAConfig,
		[ValidateSet("UsrPwd", "Kerberos", "Certificate")]
		[string]$Authentication = "Kerberos",
		[string]$User,
		[Security.SecureString]$Password,
		[switch]$RenewalOnly
	)
	if ($Host.Name -eq "ServerRemoteHost") {throw New-Object NotSupportedException}
#region Check operating system
	if ($OSVersion.Major -ne 6 -and $OSVersion.Minor -ne 1) {
		New-Object SysadminsLV.PKI.Utils.ServiceOperationResult 0x80070057, "Only Windows Server 2008 R2 operating system is supported."
		return
	}
#endregion

#region Check user permissions
# check if user has Enterprise Admins permissions
	$elevated = $false
	foreach ($sid in [Security.Principal.WindowsIdentity]::GetCurrent().Groups) {
	    if ($sid.Translate([Security.Principal.SecurityIdentifier]).IsWellKnown([Security.Principal.WellKnownSidType]::AccountEnterpriseAdminsSid)) {
	        $elevated = $true
    	}
	}
	if (!$elevated) {
		New-Object SysadminsLV.PKI.Utils.ServiceOperationResult 0x80070005, "You must be logged on with Enterprise Admins permissions."
		return
	}
#endregion

#region Obtain SSL certificate from local store or enroll new one
	function Get-Cert {
# retrieve current domain name. this suffix is used to construct current computer FQDN
		try {
			$domain = ([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()).Name
		# if command above generates error, the computer is not a member of any AD domain
		} catch {
			Write-Verbose "Current computer is not a part of any Active Directory domain!";
		}
		$fqdn = $env:COMPUTERNAME + "." + $domain
		$validCerts = @()
		# retrive all certificates from computer store that have private key and subject equals computer FQDN
		$certs = @(Get-ChildItem cert:\localmachine\my | Where-Object {$_.HasPrivateKey -and $_.subject -eq "CN=$fqdn"})
		# loop extensions for EKU extension and check for Server Authentication OID
		foreach ($cert in $certs) {
			$eku = $cert.extensions | Where-Object {$_.oid.value -eq "2.5.29.37"}
			if ($eku) {
				if ($eku.EnhancedKeyUsages | Where-Object {$_.value -eq "1.3.6.1.5.5.7.3.1"}) {
					# if certificate meet minimum requirements, write it to valid certs collection
					$validCerts += $cert
				}
			}
		}
		# sort certificates in the collection by NotAfter and select one with the longest
		# validity
		if ($validCerts.count -gt 0) {
			($validCerts | Sort-Object NotAfter | Select-Object -Last 1).Thumbprint
		} else {
			# if no valid certificate exist in the local store, enroll fro new one.
			$enrollment = New-Object -ComObject X509Enrollment.CX509enrollment
			# use ProductType of Win32_OperatingSystem class to determine computer role
			# domain Controller or Member Server.
			$ServerType = (Get-WmiObject Win32_OperatingSystem).ProductType
			if ($ServerType -eq 2) {$enrollment.InitializeFromTemplate(0x3, "DomainController")}
			elseif ($ServerType -eq 3) {$enrollment.InitializeFromTemplate(0x3, "Machine")}
			try {
				$enrollment.Enroll()
			} catch {
				Write-Verbose @"
Unable to enroll SSL certificate. In order to use CES server you will have to
manually obtain SSL certificate and configure IIS to use this certificate.
"@
				return
			}
			$base64 = $enrollment.Certificate(1)
			$cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2
			$cert.Import($([Convert]::FromBase64String($base64)))
			$cert.Thumbprint
		}
	}
#endregion

	$auth = @{"Kerberos" = 2; "UsrPwd" = 4; "Certificate" = 8}
	# we can use ServerManager module to install CES binaries
	Import-Module ServerManager
	# at first check if CES is already installed
	$status = (Get-WindowsFeature -Name ADCS-Enroll-Web-Svc).Installed
	# if still no, install binaries, otherwise do nothing
	if (!$status) {
		$retn = Add-WindowsFeature -Name ADCS-Enroll-Web-Svc
		if (!$retn.Success) {
			New-Object SysadminsLV.PKI.Utils.ServiceOperationResult 0x80070057, $retn.ExitCode
			return
		}
	}
	# instantiate CES COM object
	$CES = New-Object -ComObject CERTOCM.CertificateEnrollmentServerSetup
	$CES.InitializeInstallDefaults()
	# use ICertConfig.GetConfig() to display CA selection UI
	if ($CAConfig -eq "") {
		$config = New-Object -ComObject CertificateAuthority.Config
		try {
			$bstr = $config.GetConfig(1)
		} catch {
			New-Object SysadminsLV.PKI.Utils.ServiceOperationResult 0x80070057, "There is no available Enterprise Certification Authorities or user canceled operation."
			return
		}
	} else {$bstr = $CAConfig}
	$Thumbprint = $(Get-Cert)
	if ($User) {
		$CES.SetApplicationPoolCredentials($User, [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)))
	}
	$CES.SetProperty(0x1, $bstr)
	$CES.SetProperty(0x2, $auth.$Authentication)
	$CES.SetProperty(0x3, $Thumbprint)
	if ($RenewalOnly) {$CES.SetProperty(0x5, $true)}
	Write-Verbose @"
Performing Certificate Enrollment Service installation with the following settings:
CA configuration string    : $bstr
Authentication type        : $Authentication
Renewal Only               : $(if ($RenewalOnly) {"Yes"} else {"No"})
CES server URL             : $($CES.GetProperty(0x4))
SSL certificate thumbprint : $Thumbprint
"@ -ForegroundColor Cyan
	try {
		$CES.Install()
		New-Object SysadminsLV.PKI.Utils.ServiceOperationResult 0
	} catch {
		New-Object SysadminsLV.PKI.Utils.ServiceOperationResult $_.Exception.HResult
	}
}