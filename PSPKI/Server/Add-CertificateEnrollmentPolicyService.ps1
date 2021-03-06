function Add-CertificateEnrollmentPolicyService {
<#
.ExternalHelp PSPKI.Help.xml
#>
[OutputType('SysadminsLV.PKI.Utils.IServiceOperationResult')]
[CmdletBinding()]
	param(
		[ValidateSet("UsrPwd", "Kerberos", "Certificate")]
		[string]$Authentication = "Kerberos",
		[string]$Thumbprint
	)
	if ($Host.Name -eq "ServerRemoteHost") {throw New-Object NotSupportedException}
#region Check operating system
	if ($OSVersion.Major -ne 6 -and $OSVersion.Version.Minor -ne 1) {
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
			Write-Verbose "Current computer is not a part of any Active Directory domain!"
			return
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
			$ServerType = Get-WmiObject (Win32_OperatingSystem).ProductType
			if ($ServerType -eq 2) {$enrollment.InitializeFromTemplate(0x3, "DomainController")}
			elseif ($ServerType -eq 3) {$enrollment.InitializeFromTemplate(0x3, "Machine")}
			try {$enrollment.Enroll()}
			catch {
				Write-Verbose @"
Unable to enroll SSL certificate. In order to use CEP server you will have to
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
	# we can use ServerManager module to install CEP binaries
	Import-Module ServerManager
	# at first check if CEP is already installed
	$status = (Get-WindowsFeature -Name ADCS-Enroll-Web-Pol).Installed
	# if still no, install binaries, otherwise do nothing
	if (!$status) {$retn = Add-WindowsFeature -Name ADCS-Enroll-Web-Pol
		if (!$retn.Success) {
			New-Object SysadminsLV.PKI.Utils.ServiceOperationResult 0x80070057, $retn.ExitCode
			return
		}
	}
	# instantiate CEP COM object
	$CEP = New-Object -ComObject CERTOCM.CertificateEnrollmentPolicyServerSetup
	$CEP.InitializeInstallDefaults()
	if (!$Thumbprint) {$Thumbprint = $(Get-Cert)}
	# set required properties. Here are only two available properties: Authentication and
	# thumbprint.
	$CEP.SetProperty(0x0, $auth.$Authentication)
	$CEP.SetProperty(0x1, $Thumbprint)
	Write-Verbose @"
Performing Certificate Enrollment Service installation with the following settings:
Authentication type        : $Authentication
CEP server URL             : $($CEP.GetProperty(0x2))
SSL certificate thumbprint : $Thumbprint
"@
	# install CEP instance
	try {
		$CEP.Install()
		New-Object SysadminsLV.PKI.Utils.ServiceOperationResult 0
	} catch {
		New-Object SysadminsLV.PKI.Utils.ServiceOperationResult $_.Exception.HResult
	}
}