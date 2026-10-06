# letsencrypt-recipe - https://github.com/Signal-Point-Technologies/letsencrypt-recipe
# Author : Andrew Cohen, Signal Point Technologies
# License: MIT
<#
=====================================================================
 PART 1 of 4 - Install prerequisites (PowerShell 7 + modules)
=====================================================================
 RUN AS   : Any local administrator, ELEVATED
 RUN IN   : Windows PowerShell 5.1 OR PowerShell 7 (this is the only
            script that may be run from 5.1 - everything after this
            MUST be run in pwsh 7)
 RUN ONCE : Yes (safe to re-run; all steps are idempotent)

 WHAT IT DOES
   1. Forces TLS 1.2 (fresh Server 2022 sessions sometimes default lower)
   2. Installs PowerShell 7 via winget (or tells you the MSI fallback)
   3. Installs NuGet provider + trusts PSGallery
   4. Installs Posh-ACME, SecretManagement, SecretStore for AllUsers
   5. Installs the EasyDNSFix custom plugin (REQUIRED - the built-in
      'EasyDNS' plugin is broken against easyDNS's current API, which
      returns errors as HTTP 200; confirmed against the live API).
      EasyDNSFix.ps1 must sit in the same folder as this script.

 EXAMPLE
   PS C:\> Set-ExecutionPolicy RemoteSigned -Scope Process -Force
   PS C:\> .\01-Install-Prereqs.ps1

 NEXT STEP
   Log in (or start pwsh) AS THE SERVICE ACCOUNT that will run the
   renewal task, then run 02-Setup-Vault-Account.ps1 in pwsh 7.
=====================================================================
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "== [1/4] Checking for PowerShell 7 ==" -ForegroundColor Cyan
$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwsh) {
    Write-Host "PowerShell 7 already installed: $($pwsh.Source)"
} else {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host "Installing PowerShell 7 via winget..."
        winget install Microsoft.PowerShell --accept-source-agreements --accept-package-agreements
    } else {
        Write-Warning "winget not available on this server."
        Write-Warning "Download and run the MSI manually, then re-run this script:"
        Write-Warning "  https://github.com/PowerShell/PowerShell/releases (PowerShell-7.x.x-win-x64.msi)"
        throw "PowerShell 7 not installed."
    }
}

Write-Host "== [2/4] NuGet provider + PSGallery trust ==" -ForegroundColor Cyan
if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
    Install-PackageProvider -Name NuGet -Force | Out-Null
}
if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
}

Write-Host "== [3/4] Installing modules (AllUsers) ==" -ForegroundColor Cyan
foreach ($m in 'Posh-ACME','Microsoft.PowerShell.SecretManagement','Microsoft.PowerShell.SecretStore') {
    if (Get-Module $m -ListAvailable) {
        Write-Host "  $m already installed"
    } else {
        Write-Host "  Installing $m..."
        Install-Module $m -Scope AllUsers -Force
    }
}

Write-Host "== [4/5] Verify modules ==" -ForegroundColor Cyan
Get-Module Posh-ACME,Microsoft.PowerShell.SecretManagement,Microsoft.PowerShell.SecretStore -ListAvailable |
    Select-Object Name, Version | Format-Table -AutoSize

Write-Host "== [5/5] Installing EasyDNSFix plugin ==" -ForegroundColor Cyan
# The built-in EasyDNS plugin mis-detects zones because easyDNS returns
# errors as HTTP 200. EasyDNSFix corrects that and paces calls at 1.5s
# to respect easyDNS's hard 1 request/second rate limit.
$pluginSrc = Join-Path $PSScriptRoot 'EasyDNSFix.ps1'
if (-not (Test-Path $pluginSrc)) {
    Write-Warning "EasyDNSFix.ps1 not found next to this script - copy it here and re-run, or install it manually."
} else {
    $pluginDir = 'C:\ProgramData\Posh-ACME-Plugins'
    New-Item -ItemType Directory -Force -Path $pluginDir | Out-Null
    Copy-Item $pluginSrc $pluginDir -Force
    [Environment]::SetEnvironmentVariable('POSHACME_PLUGINS', $pluginDir, 'Machine')
    # Also drop it into the module's own Plugins folder as a belt-and-braces
    # fallback (survives sessions that inherited a stale environment).
    Get-Module Posh-ACME -ListAvailable | ForEach-Object {
        Copy-Item $pluginSrc (Join-Path $_.ModuleBase 'Plugins') -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  EasyDNSFix installed to $pluginDir and the module Plugins folder(s)."
    Write-Host "  NOTE: verify later in a NEW pwsh window with:  Get-PAPlugin | ? Name -eq EasyDNSFix" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "DONE. NEXT:" -ForegroundColor Green
Write-Host "  1. Log in (or 'runas') as the SERVICE ACCOUNT that will own cert automation." -ForegroundColor Yellow
Write-Host "  2. Open pwsh 7 (NOT Windows PowerShell 5.1)." -ForegroundColor Yellow
Write-Host "  3. Run 02-Setup-Vault-Account.ps1" -ForegroundColor Yellow
Write-Host ""
Write-Host "WHY THE ACCOUNT MATTERS: the secret vault AND all Posh-ACME state" -ForegroundColor Yellow
Write-Host "(accounts, orders, certs) live in that user's profile" -ForegroundColor Yellow
Write-Host "(`$env:LOCALAPPDATA\Posh-ACME). A different account sees NOTHING." -ForegroundColor Yellow
