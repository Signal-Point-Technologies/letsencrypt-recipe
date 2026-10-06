# letsencrypt-recipe - https://github.com/Signal-Point-Technologies/letsencrypt-recipe
# Author : Andrew Cohen, Signal Point Technologies
# License: MIT
<#
=====================================================================
 PART 3 of 4 - Staging dry-run: issue a test cert for EVERY zone
=====================================================================
 RUN AS   : Same service account as Part 2, in pwsh 7
 RUN ONCE : Re-run freely; staging has no meaningful rate limits

 WHAT IT DOES
   Issues Let's Encrypt STAGING certs via easyDNS DNS-01 for one name
   in each zone you manage. Passing every zone = the Phase 1 gate in
   the runbook is closed and you may move to production for the pilot
   host.

 USES THE 'EasyDNSFix' PLUGIN - NOT the built-in 'EasyDNS' plugin.
   The built-in plugin is broken against easyDNS's current API (it
   treats easyDNS's HTTP-200-wrapped errors as "zone found" and writes
   the TXT into a nonexistent zone -> NXDOMAIN at validation).
   EasyDNSFix is installed by 01-Install-Prereqs.ps1.

 NOTES
   - Staging certs are UNTRUSTED by design (issuer says "(STAGING)").
     They prove the pipeline only. Never deploy them to a host.
   - easyDNS rate-limits hard (HTTP 420 "Enhance Your Calm").
     This script issues the two certs with a pause between them.
     If you hit 420, wait a few minutes and re-run.
   - If validation fails with a timeout, raise -DnsSleep (propagation).

 EXAMPLE
   PS C:\> .\03-Test-StagingCert.ps1 -Hosts 'web01.example.com','vpn1.example.net'
   PS C:\> .\03-Test-StagingCert.ps1 -Hosts 'test.example.com'
   PS C:\> .\03-Test-StagingCert.ps1 -Hosts 'web01.example.com' -DnsSleep 300   # slow DNS

 NEXT STEP
   Run 04-Register-RenewalTask.ps1 (elevated) to create the daily
   scheduled renewal task. Production issuance for the pilot host
   happens per runbook Phase 2 (Set-PAServer LE_PROD).
=====================================================================
#>

param(
    # One representative name per zone you manage, e.g. 'web01.example.com','vpn1.example.net'
    [Parameter(Mandatory)][string[]]$Hosts,
    [int]$DnsSleep = 120
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "Run this in pwsh 7. Type 'pwsh' first."
}

# The fixed plugin must be registered (installed by 01-Install-Prereqs.ps1)
if (-not (Get-PAPlugin | Where-Object Name -eq 'EasyDNSFix')) {
    # A session that inherited a stale environment may miss POSHACME_PLUGINS
    $env:POSHACME_PLUGINS = 'C:\ProgramData\Posh-ACME-Plugins'
    Import-Module Posh-ACME -Force
    if (-not (Get-PAPlugin | Where-Object Name -eq 'EasyDNSFix')) {
        throw "EasyDNSFix plugin not registered. Re-run 01-Install-Prereqs.ps1 (it copies EasyDNSFix.ps1 into place), then open a NEW pwsh window."
    }
}

# Pull creds from the vault (must be the same account that ran Part 2)
try {
    $pArgs = @{
        EDToken = (Get-Secret EasyDNS-Token -AsPlainText)
        EDKey   = (Get-Secret EasyDNS-Key -AsPlainText)
    }
} catch {
    throw "Cannot read vault secrets. Are you the same account that ran 02-Setup-Vault-Account.ps1? ($env:USERDOMAIN\$env:USERNAME)"
}

# Force STAGING - this script must never touch production
Set-PAServer LE_STAGE
Write-Host "ACME server: $((Get-PAServer).location)" -ForegroundColor Cyan
if ((Get-PAServer).location -notlike '*staging*') { throw "Not on staging server - aborting." }

$results = @()
foreach ($h in $Hosts) {
    Write-Host "== Issuing STAGING cert for $h (DnsSleep $DnsSleep s) ==" -ForegroundColor Cyan
    try {
        $cert = New-PACertificate $h -Plugin EasyDNSFix -PluginArgs $pArgs -DnsSleep $DnsSleep -Verbose -Force
        $results += [pscustomobject]@{ Host = $h; Result = 'PASS'; NotAfter = $cert.NotAfter; Files = Split-Path $cert.CertFile }
        Write-Host "PASS: $h" -ForegroundColor Green
    } catch {
        $results += [pscustomobject]@{ Host = $h; Result = "FAIL: $($_.Exception.Message)"; NotAfter = $null; Files = $null }
        Write-Warning "FAIL: $h - $($_.Exception.Message)"
    }
    if ($h -ne $Hosts[-1]) {
        Write-Host "Pausing 60s between issuances (easyDNS rate limit)..." -ForegroundColor Yellow
        Start-Sleep -Seconds 60
    }
}

Write-Host ""
Write-Host "== RESULTS ==" -ForegroundColor Cyan
$results | Format-Table -AutoSize -Wrap

Write-Host ""
if ($results.Result -notmatch '^PASS') {
    Write-Warning "One or more failures - do NOT proceed to production until every zone passes."
    Write-Warning "Common causes:"
    Write-Warning " - 420 'Enhance Your Calm' on the FIRST call = wrong/stale/swapped creds (re-run 02 to re-verify),"
    Write-Warning "   on later calls = rate limit (1 req/sec, 500/day; wait, then ONE retry)."
    Write-Warning " - Validation timeout = DNS propagation; retry with -DnsSleep 300."
    Write-Warning " - Connection/JSON errors to letsencrypt.org = proxy/FortiGate interception of outbound 443."
} else {
    Write-Host "ALL ZONES PASS - Phase 1 gate closed." -ForegroundColor Green
    Write-Host "NEXT: .\04-Register-RenewalTask.ps1 (elevated), then runbook Phase 2 (pilot) using:" -ForegroundColor Green
    Write-Host "  Set-PAServer LE_PROD; New-PAAccount -AcceptTOS -Contact 'mailto:<your-contact-email>'" -ForegroundColor Green
}
