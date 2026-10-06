# letsencrypt-recipe - https://github.com/Signal-Point-Technologies/letsencrypt-recipe
# Author : Andrew Cohen, Signal Point Technologies
# License: MIT
<#
=====================================================================
 PART 6 - Bind a store-imported cert to an IIS site's HTTPS binding
=====================================================================
 RUN ON   : The TARGET web server (the host that serves the site), not the
            orchestrator - after 05-Import-CertToStore.ps1 put the
            cert in LocalMachine\My on that machine.
 RUN AS   : Administrator, ELEVATED.
 SHELL    : Windows PowerShell 5.1 or pwsh 7 (uses WebAdministration).

 WHY THIS RUNS EVERY RENEWAL
   IIS binds by THUMBPRINT, and the thumbprint is a hash of the whole
   certificate - it changes at every renewal even though Posh-ACME
   reuses the same private key by default. So the per-renewal deploy
   for an IIS host is always: import (05) then rebind (06).

 WHAT IT DOES
   1. Finds the cert: -Thumbprint explicit, or -Domain picks the
      NEWEST valid cert in LocalMachine\My whose SAN covers the name
   2. Ensures the site has an https binding (creates it if missing)
   3. Points that binding at the cert (replaces the previous cert)
   4. Verifies, prints the old thumbprint for rollback

 EXAMPLES
   # Typical: newest cert for the FQDN onto Default Web Site *:443
   PS C:\> .\06-Bind-IISCert.ps1 -Domain web01.example.com

   # Explicit thumbprint, named site, SNI host header:
   PS C:\> .\06-Bind-IISCert.ps1 -Thumbprint 0123456789ABCDEF0123456789ABCDEF01234567 `
             -SiteName 'Portal' -HostHeader 'portal.example.com'

   # Preview only:
   PS C:\> .\06-Bind-IISCert.ps1 -Domain web01.example.com -WhatIf

 ROLLBACK
   Re-run with -Thumbprint <old thumbprint> (printed by this script
   before it switches). The old cert stays in the store until you
   deliberately remove it (05's -RemoveSuperseded or certlm.msc).
=====================================================================
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Domain')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Domain')]
    [string]$Domain,

    [Parameter(Mandatory, ParameterSetName = 'Thumbprint')]
    [string]$Thumbprint,

    [string]$SiteName = 'Default Web Site',
    [int]$Port = 443,
    # Set for SNI-bound sites. Empty = bind to *:443 for all names.
    [string]$HostHeader = '',
    [string]$IPAddress = '*'
)

$ErrorActionPreference = 'Stop'

# WebAdministration in pwsh 7 loads via a compat session and returns
# DESERIALIZED objects (no methods -> AddSslCertificate fails). This module
# needs real Windows PowerShell 5.1, so relaunch there transparently.
if ($PSVersionTable.PSVersion.Major -ge 6) {
    Write-Host '[*] WebAdministration needs Windows PowerShell 5.1 - relaunching...' -ForegroundColor Cyan
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $PSCommandPath)
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [System.Management.Automation.SwitchParameter] -or $kv.Value -is [bool]) {
            if ($kv.Value) { $argList += "-$($kv.Key)" }
        } else {
            $argList += "-$($kv.Key)"; $argList += "$($kv.Value)"
        }
    }
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @argList
    exit $LASTEXITCODE
}

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'IIS binding changes require an ELEVATED session.' }

Import-Module WebAdministration -ErrorAction Stop

# ---------------------------------------------------------------------
# 1. Resolve the certificate
# ---------------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'Domain') {
    $matches0 = @(Get-ChildItem Cert:\LocalMachine\My |
        Where-Object {
            $_.HasPrivateKey -and
            $_.NotAfter -gt (Get-Date) -and
            ($_.DnsNameList.Unicode -contains $Domain)
        })
    if (-not $matches0) { throw "No valid cert with a private key covering '$Domain' in LocalMachine\My. Run 05-Import-CertToStore.ps1 first." }
    # Most recently ISSUED wins (NotBefore). Sorting by expiry would wrongly
    # prefer a leftover 1-year GoDaddy cert over a fresh 90-day LE cert.
    $cert = $matches0 | Sort-Object NotBefore -Descending | Select-Object -First 1
    if ($matches0.Count -gt 1) {
        Write-Host "[!] $($matches0.Count) certs cover '$Domain' - picked the newest-issued. All matches:" -ForegroundColor Yellow
        $matches0 | Sort-Object NotBefore -Descending |
            ForEach-Object { Write-Host ("      {0}  issued {1:d}  expires {2:d}  [{3}]" -f $_.Thumbprint, $_.NotBefore, $_.NotAfter, ($_.Issuer -split ',')[0]) -ForegroundColor Yellow }
        Write-Host "    Wrong pick? Re-run with -Thumbprint <the right one>." -ForegroundColor Yellow
    }
} else {
    $Thumbprint = $Thumbprint -replace '\s',''
    $cert = Get-Item "Cert:\LocalMachine\My\$Thumbprint" -ErrorAction SilentlyContinue
    if (-not $cert) { throw "Thumbprint $Thumbprint not found in LocalMachine\My." }
    if (-not $cert.HasPrivateKey) { throw "Cert $Thumbprint has no private key - re-import via script 05." }
}

if ($cert.Issuer -match 'STAGING') {
    Write-Warning "This is a Let's Encrypt STAGING cert - clients will NOT trust it."
    if (-not $WhatIfPreference) {
        if ((Read-Host 'Bind the STAGING cert anyway? (y/n)') -ne 'y') { throw 'Aborted: staging cert.' }
    }
}

Write-Host "Cert    : $($cert.Subject)  ($($cert.Thumbprint))" -ForegroundColor Cyan
Write-Host "Issuer  : $($cert.Issuer)" -ForegroundColor Cyan
Write-Host "Expires : $($cert.NotAfter)" -ForegroundColor Cyan

# ---------------------------------------------------------------------
# 2. Ensure the https binding exists on the site
# ---------------------------------------------------------------------
if (-not (Get-Website -Name $SiteName -ErrorAction SilentlyContinue)) {
    throw "IIS site '$SiteName' not found. Sites here: $((Get-Website).Name -join ', ')"
}

$bindingInfo = "${IPAddress}:${Port}:${HostHeader}"
$binding = Get-WebBinding -Name $SiteName -Protocol https |
    Where-Object bindingInformation -eq $bindingInfo

if (-not $binding) {
    if ($PSCmdlet.ShouldProcess("$SiteName", "Create https binding $bindingInfo")) {
        $sslFlags = if ($HostHeader) { 1 } else { 0 }   # 1 = SNI
        New-WebBinding -Name $SiteName -Protocol https -IPAddress $IPAddress `
            -Port $Port -HostHeader $HostHeader -SslFlags $sslFlags
        $binding = Get-WebBinding -Name $SiteName -Protocol https |
            Where-Object bindingInformation -eq $bindingInfo
        Write-Host "[+] Created https binding $bindingInfo (SNI: $([bool]$HostHeader))" -ForegroundColor Green
    } else { return }
}

# ---------------------------------------------------------------------
# 3. Record the current cert (rollback), then switch
# ---------------------------------------------------------------------
$sslPath = if ($HostHeader) { "IIS:\SslBindings\!${Port}!${HostHeader}" }
           else { "IIS:\SslBindings\0.0.0.0!${Port}" }
$existing = Get-Item $sslPath -ErrorAction SilentlyContinue
if ($existing -and $existing.Thumbprint -and $existing.Thumbprint -ne $cert.Thumbprint) {
    Write-Host "[!] ROLLBACK REFERENCE - current cert on this binding: $($existing.Thumbprint)" -ForegroundColor Yellow
}
if ($existing -and $existing.Thumbprint -eq $cert.Thumbprint) {
    Write-Host "[+] Binding already uses this cert - nothing to do." -ForegroundColor Green
    return
}

if ($PSCmdlet.ShouldProcess("$SiteName $bindingInfo", "Bind cert $($cert.Thumbprint)")) {
    # AddSslCertificate replaces any cert currently on the binding
    $binding.AddSslCertificate($cert.Thumbprint, 'My')
    Write-Host "[+] Bound $($cert.Thumbprint) to $SiteName ($bindingInfo)" -ForegroundColor Green
}

# ---------------------------------------------------------------------
# 4. Verify
# ---------------------------------------------------------------------
$check = Get-Item $sslPath -ErrorAction SilentlyContinue
if ($check.Thumbprint -eq $cert.Thumbprint) {
    Write-Host "[+] Verified: SSL binding now serves $($cert.Thumbprint)" -ForegroundColor Green
} elseif (-not $WhatIfPreference) {
    Write-Warning "Verification mismatch - check manually: Get-ChildItem IIS:\SslBindings"
}

Write-Host ''
Write-Host 'Prove it end-to-end from another machine:' -ForegroundColor DarkGray
$testName = if ($HostHeader) { $HostHeader } elseif ($PSCmdlet.ParameterSetName -eq 'Domain') { $Domain } else { '<fqdn>' }
Write-Host "  openssl s_client -connect <host>:$Port -servername $testName </dev/null | openssl x509 -noout -issuer -dates" -ForegroundColor DarkGray
