# letsencrypt-recipe - https://github.com/Signal-Point-Technologies/letsencrypt-recipe
# Author : Andrew Cohen, Signal Point Technologies
# License: MIT
<#
=====================================================================
 PART 8 - ACME Doctor: health-check + repair for the whole pipeline
=====================================================================
 RUN AS   : The SERVICE ACCOUNT, pwsh 7. ELEVATED if you
            want store/binding repairs to work.
 RUN WHEN : Anything misbehaves, after any incident, or as a periodic
            sanity check. Read-only by default; -Repair applies fixes.

 CHECKS (each modeled on a failure that happened for real)
   1. Shell + profile context (pwsh 7, Posh-ACME state present)
   2. EasyDNSFix plugin registered            [repair: reinstall+reload]
   3. Vault secrets present + LIVE cred check [repair: swap if reversed]
      (costs 1-2 easyDNS API calls - skip with -SkipApiCheck)
   4. Orders using the broken built-in 'EasyDNS' plugin
                                              [repair: Set-PAOrder EasyDNSFix]
   5. Old stuck 'pending' orders              [warn: Remove-PAOrder cmd given]
   6. Keyless certs in LocalMachine\My ("Keyset does not exist")
                                              [repair: reimport via script 05]
   7. IIS binding serves the newest-issued LE cert per domain
                                              [repair: rebind via script 06]
   8. ACME-Renewal scheduled task exists and points at script 07

 EXAMPLES
   PS C:\> .\08-AcmeDoctor.ps1 -VerifyZone example.com                 # report only
   PS C:\> .\08-AcmeDoctor.ps1 -VerifyZone example.com -Repair         # report + fix what it can
   PS C:\> .\08-AcmeDoctor.ps1 -SkipApiCheck -Repair                   # no easyDNS calls
   PS C:\> .\08-AcmeDoctor.ps1 -VerifyZone example.com -LocalDomains web01.example.com

 EXIT CODE: 0 all pass; 1 issues found (or found-and-repaired - re-run
 to confirm clean); check the summary table either way.

 AFTER ANY KEY-RELATED REPAIR: validate survival of a restart -
 iisreset, then load the site from another machine. In-memory keys can
 mask a broken on-disk keyset until the next restart.
=====================================================================
#>

[CmdletBinding()]
param(
    [switch]$Repair,
    [switch]$SkipApiCheck,
    # A zone in the easyDNS account, used for the live credential check.
    # Required unless -SkipApiCheck.
    [string]$VerifyZone,
    # Domains whose store/binding health to verify locally (the hosts THIS
    # machine serves). Others are covered by order checks only.
    [string[]]$LocalDomains = @()
)
if (-not $SkipApiCheck -and -not $VerifyZone) {
    throw "Pass -VerifyZone <zone in your easyDNS account> or -SkipApiCheck."
}

$ErrorActionPreference = 'Stop'
$issues = [System.Collections.Generic.List[object]]::new()

function Report([string]$Check, [string]$State, [string]$Detail) {
    $color = switch ($State) { 'PASS' {'Green'} 'FIXED' {'Green'} 'FAIL' {'Red'} default {'Yellow'} }
    Write-Host ("[{0,-5}] {1} - {2}" -f $State, $Check, $Detail) -ForegroundColor $color
    if ($State -notin 'PASS','FIXED') { $script:issues.Add([pscustomobject]@{Check=$Check; State=$State; Detail=$Detail}) }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# --- 1. Context -------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Run in pwsh 7.' }
Write-Host "Context: $env:USERDOMAIN\$env:USERNAME  elevated=$isAdmin  pwsh $($PSVersionTable.PSVersion)" -ForegroundColor Cyan
Import-Module Posh-ACME -ErrorAction Stop
if (Test-Path (Join-Path $env:LOCALAPPDATA 'Posh-ACME')) {
    Report 'State' 'PASS' "Posh-ACME state present in this profile"
} else {
    Report 'State' 'FAIL' "No Posh-ACME state in $env:LOCALAPPDATA - wrong account? (must be the ACME service account)"
}

# --- 2. Plugin --------------------------------------------------------
if (Get-PAPlugin | Where-Object Name -eq 'EasyDNSFix') {
    Report 'Plugin' 'PASS' 'EasyDNSFix registered'
} elseif ($Repair) {
    $src = Join-Path $PSScriptRoot 'EasyDNSFix.ps1'
    if (-not (Test-Path $src)) { Report 'Plugin' 'FAIL' 'EasyDNSFix.ps1 missing from scripts folder' }
    else {
        $dir = 'C:\ProgramData\Posh-ACME-Plugins'
        New-Item -ItemType Directory -Force $dir | Out-Null
        Copy-Item $src $dir -Force
        [Environment]::SetEnvironmentVariable('POSHACME_PLUGINS', $dir, 'Machine')
        $env:POSHACME_PLUGINS = $dir
        Import-Module Posh-ACME -Force
        if (Get-PAPlugin | Where-Object Name -eq 'EasyDNSFix') { Report 'Plugin' 'FIXED' 'EasyDNSFix reinstalled + reloaded' }
        else { Report 'Plugin' 'FAIL' 'Reinstall did not register - open a NEW pwsh window and re-run' }
    }
} else {
    Report 'Plugin' 'FAIL' 'EasyDNSFix not registered (run with -Repair, or re-run script 01)'
}

# --- 3. Credentials ---------------------------------------------------
$tok = $null; $key = $null
try {
    $tok = Get-Secret EasyDNS-Token -AsPlainText
    $key = Get-Secret EasyDNS-Key -AsPlainText
    Report 'Vault' 'PASS' 'EasyDNS-Token / EasyDNS-Key readable'
} catch {
    Report 'Vault' 'FAIL' "Cannot read vault secrets: $($_.Exception.Message) (wrong account, or re-run script 02)"
}

if ($tok -and $key -and -not $SkipApiCheck) {
    function Test-EDAuth([string]$T,[string]$K) {
        $auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${T}:${K}"))
        try {
            $r = Invoke-RestMethod "https://rest.easydns.net/zones/records/all/$VerifyZone`?format=json" -Headers @{Authorization=$auth}
            return (-not $r.PSObject.Properties['error'])
        } catch { return $false }
    }
    if (Test-EDAuth $tok $key) {
        Report 'Creds' 'PASS' 'easyDNS accepts the stored Token/Key'
    } else {
        Start-Sleep -Seconds 3
        if (Test-EDAuth $key $tok) {
            if ($Repair) {
                Set-Secret -Name EasyDNS-Token -Secret $key
                Set-Secret -Name EasyDNS-Key   -Secret $tok
                $tmp = $tok; $tok = $key; $key = $tmp
                Report 'Creds' 'FIXED' 'Token/Key were stored reversed - swapped in the vault'
            } else {
                Report 'Creds' 'FAIL' 'Token/Key are stored REVERSED (run with -Repair to swap)'
            }
        } else {
            Report 'Creds' 'WARN' 'Both orders got 420: stale pair (someone regenerated?) OR rate limit - verify on the easyDNS portal; if rate limited, retry after 12AM EST'
        }
    }
}

# --- 4 + 5. Orders ----------------------------------------------------
foreach ($srv in 'LE_PROD','LE_STAGE') {
    try { Set-PAServer $srv } catch { Report "Orders($srv)" 'WARN' "Cannot select server: $($_.Exception.Message)"; continue }
    $orders = @(Get-PAOrder -List -ErrorAction SilentlyContinue)
    foreach ($o in $orders) {
        if ($o.Plugin -contains 'EasyDNS') {
            if ($Repair -and $tok) {
                Set-PAOrder -MainDomain $o.MainDomain -Plugin EasyDNSFix -PluginArgs @{EDToken=$tok; EDKey=$key} | Out-Null
                Report "Order $($o.MainDomain)" 'FIXED' "was on broken built-in EasyDNS plugin - switched to EasyDNSFix ($srv)"
            } else {
                Report "Order $($o.MainDomain)" 'FAIL' "uses broken built-in EasyDNS plugin ($srv) - run with -Repair"
            }
        }
        if ($o.status -eq 'pending' -and $o.expires -and ([datetime]$o.expires) -lt (Get-Date)) {
            Report "Order $($o.MainDomain)" 'WARN' "stuck expired-pending order ($srv) - clear with: Set-PAServer $srv; Remove-PAOrder $($o.MainDomain) -Force"
        }
    }
    if (-not $orders) { Write-Host "  (${srv}: no orders)" -ForegroundColor DarkGray }
}
Set-PAServer LE_PROD   # leave production selected - the daily runner expects it

# --- 6. Keyless store certs ------------------------------------------
foreach ($d in $LocalDomains) {
    $certs = @(Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.DnsNameList.Unicode -contains $d })
    if (-not $certs) { Report "Store $d" 'WARN' 'no cert in LocalMachine\My (run script 05 after issuance)'; continue }
    foreach ($c in $certs) {
        $keyOk = $false
        try {
            if ($c.HasPrivateKey) {
                $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($c)
                if (-not $rsa) { $rsa = [Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($c) }
                # Touching the key object forces the "Keyset does not exist" error out of hiding
                $null = $rsa.KeySize
                $keyOk = $true
            }
        } catch { $keyOk = $false }
        if ($keyOk) {
            Report "Store $d" 'PASS' "$($c.Thumbprint.Substring(0,12))... private key healthy"
        } elseif ($Repair -and $isAdmin) {
            Remove-Item "Cert:\LocalMachine\My\$($c.Thumbprint)" -Force
            & (Join-Path $PSScriptRoot '05-Import-CertToStore.ps1') -MainDomain $d -InstallChain -Confirm:$false | Out-Null
            Report "Store $d" 'FIXED' "keyless cert $($c.Thumbprint.Substring(0,12))... removed + reimported from Posh-ACME PFX. VALIDATE: iisreset, then load the site externally"
        } else {
            Report "Store $d" 'FAIL' "$($c.Thumbprint.Substring(0,12))... has NO usable private key (Keyset does not exist) - run elevated with -Repair"
        }
    }
}

# --- 7. Binding serves the newest-issued LE cert ---------------------
foreach ($d in $LocalDomains) {
    $want = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) -and ($_.DnsNameList.Unicode -contains $d) -and $_.Issuer -notmatch 'STAGING' } |
        Sort-Object NotBefore -Descending | Select-Object -First 1
    if (-not $want) { continue }
    $ssl = (netsh http show sslcert) -join "`n"
    if ($ssl -match [regex]::Escape($want.Thumbprint)) {
        Report "Binding $d" 'PASS' "http.sys serves the newest-issued cert $($want.Thumbprint.Substring(0,12))..."
    } elseif ($Repair -and $isAdmin) {
        & (Join-Path $PSScriptRoot '06-Bind-IISCert.ps1') -Thumbprint $want.Thumbprint -Confirm:$false | Out-Null
        Report "Binding $d" 'FIXED' "rebound to $($want.Thumbprint.Substring(0,12))..."
    } else {
        Report "Binding $d" 'FAIL' "http.sys is NOT serving the newest cert - run with -Repair, or script 06"
    }
}

# --- 8. Scheduled task -----------------------------------------------
$task = Get-ScheduledTask -TaskName 'ACME-Renewal' -ErrorAction SilentlyContinue
if (-not $task) {
    Report 'Task' 'FAIL' "ACME-Renewal task missing - run script 04"
} elseif (($task.Actions.Arguments -join ' ') -match '07-Renew-And-Deploy') {
    Report 'Task' 'PASS' "ACME-Renewal runs 07-Renew-And-Deploy.ps1 (state: $($task.State))"
} else {
    Report 'Task' 'WARN' 'ACME-Renewal exists but does NOT run script 07 (renews without deploying) - re-run script 04'
}

# --- Summary ----------------------------------------------------------
Write-Host ''
if ($issues.Count -eq 0) {
    Write-Host 'DOCTOR: all checks passed.' -ForegroundColor Green
    exit 0
}
Write-Host "DOCTOR: $($issues.Count) issue(s):" -ForegroundColor Yellow
$issues | Format-Table -AutoSize
if (-not $Repair) { Write-Host 'Re-run with -Repair (elevated) to apply automatic fixes.' -ForegroundColor Yellow }
else { Write-Host 'Re-run once more to confirm a clean bill of health.' -ForegroundColor Yellow }
exit 1
