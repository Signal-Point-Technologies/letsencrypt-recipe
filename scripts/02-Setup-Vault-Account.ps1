# letsencrypt-recipe - https://github.com/Signal-Point-Technologies/letsencrypt-recipe
# Author : Andrew Cohen, Signal Point Technologies
# License: MIT
<#
=====================================================================
 PART 2 of 4 - Secret vault + easyDNS creds + Let's Encrypt account
=====================================================================
 RUN AS   : *** THE SERVICE ACCOUNT *** that will run the scheduled
            renewal task. NOT your own admin account.
            >>> The vault and ALL Posh-ACME state are PROFILE-SPECIFIC.
            >>> Whatever account runs this script is the account the
            >>> scheduled task in Part 4 MUST use. <<<
 RUN IN   : pwsh 7 (check: $PSVersionTable.PSVersion -> 7.x)
            If your console is Windows PowerShell 5.1, type: pwsh
 RUN ONCE : Yes per service account (idempotent; re-running lets you
            overwrite the stored secrets)

 WHAT IT DOES
   1. Registers the 'AcmeCerts' SecretStore vault
   2. Configures the vault for UNATTENDED use (no password prompt -
      required or the scheduled task hangs forever)
   3. Prompts you to paste the easyDNS production Token and Key,
      then LIVE-VERIFIES them against the API - including detecting
      and auto-correcting a swapped Token/Key (this happened for real:
      the pair was stored backwards and produced misleading 420s)
   4. Points Posh-ACME at Let's Encrypt STAGING and creates the account

 EASYDNS CREDENTIAL FACTS (learned the hard way)
   - Enter each string exactly as LABELED on the easyDNS
     "Production Details" page. Prefixes mean nothing - easyDNS
     builds the string from whatever NAME the person typed when
     generating the token, so 'api...', 'ABC...', 'u6a...' are all
     possible for either value.
   - The Key is displayed ONLY at creation. If it wasn't captured,
     REGENERATE and capture both. Regenerating INSTANTLY kills the
     previous pair - coordinate so nobody regenerates after you store.
   - Wrong/stale creds and rate limiting return the SAME error:
     HTTP 200 with a 420 "Enhance Your Calm" JSON body. This script's
     live verification is what tells those cases apart.
   - Rate limits: 1 request/second, 500/day, daily reset 12AM EST.
     Verification below costs 1-2 API calls.

 EXAMPLE
   PS C:\> pwsh
   PS C:\> cd "<this scripts folder>"
   PS C:\> .\02-Setup-Vault-Account.ps1 -VerifyZone example.com -ContactEmail certs@example.com
   Paste easyDNS TOKEN (as labeled on the portal page): ********
   Paste easyDNS KEY   (as labeled on the portal page): ********
   == Verifying credentials against the live API ==
     Stored order works - credentials verified.

 PARAMETERS
   -VerifyZone    a zone in this easyDNS account (used for the live
                  credential check - one read-only API call)
   -ContactEmail  Let's Encrypt account contact (prompted if omitted)
   -VaultName     SecretStore vault name (default 'AcmeCerts')

 NEXT STEP
   Run 03-Test-StagingCert.ps1 (same account, same pwsh) to prove
   DNS-01 works for every zone against LE staging.
=====================================================================
#>

param(
    # A zone hosted in this easyDNS account, e.g. 'example.com'. Used only
    # for the live credential verification (one read-only API call).
    [Parameter(Mandatory)][string]$VerifyZone,
    # Contact address for the Let's Encrypt account. Prompted if omitted.
    [string]$ContactEmail,
    [string]$VaultName = 'AcmeCerts'
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "Run this in pwsh 7, not Windows PowerShell $($PSVersionTable.PSVersion). Type 'pwsh' first."
}

Write-Host "Running as: $env:USERDOMAIN\$env:USERNAME" -ForegroundColor Cyan
Write-Host "REMINDER: this MUST be the service account the renewal task will use." -ForegroundColor Yellow
$ok = Read-Host "Continue as this account? (y/n)"
if ($ok -ne 'y') { throw "Aborted. Log in as the service account and re-run." }

Write-Host "== [1/4] Registering secret vault ==" -ForegroundColor Cyan
if (Get-SecretVault -Name $VaultName -ErrorAction SilentlyContinue) {
    Write-Host "  Vault '$VaultName' already registered."
} else {
    Register-SecretVault -Name $VaultName -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault
    Write-Host "  Vault registered."
}

Write-Host "== [2/4] Configuring vault for unattended use ==" -ForegroundColor Cyan
# Authentication None = no vault password; secrets still encrypted at rest
# via DPAPI, bound to THIS Windows account. Required for scheduled tasks.
Set-SecretStoreConfiguration -Authentication None -Interaction None -Confirm:$false

Write-Host "== [3/4] Storing + verifying easyDNS credentials ==" -ForegroundColor Cyan
Write-Host "  Enter each value exactly as LABELED on the easyDNS Production Details page." -ForegroundColor Yellow
Write-Host "  (Prefixes like 'api'/'ABC'/'u6a' mean nothing - they come from the token's name.)" -ForegroundColor Yellow
$tokSS = Read-Host "Paste easyDNS TOKEN (as labeled on the portal page)" -AsSecureString
$keySS = Read-Host "Paste easyDNS KEY   (as labeled on the portal page)" -AsSecureString
$tok = [pscredential]::new('a',$tokSS).GetNetworkCredential().Password.Trim()
$key = [pscredential]::new('a',$keySS).GetNetworkCredential().Password.Trim()

Write-Host "== Verifying credentials against the live API (1-2 calls) ==" -ForegroundColor Cyan
function Test-EasyDnsAuth([string]$T, [string]$K) {
    $auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${T}:${K}"))
    try {
        $r = Invoke-RestMethod "https://rest.easydns.net/zones/records/all/$VerifyZone`?format=json" `
             -Headers @{ Authorization = $auth }
        # easyDNS serves errors as HTTP 200 with an .error body
        return (-not $r.PSObject.Properties['error'])
    } catch { return $false }
}

if (Test-EasyDnsAuth $tok $key) {
    Write-Host "  Stored order works - credentials verified." -ForegroundColor Green
} else {
    Write-Host "  As-entered order rejected; testing swapped order..." -ForegroundColor Yellow
    Start-Sleep -Seconds 3   # respect the 1 req/sec limit
    if (Test-EasyDnsAuth $key $tok) {
        Write-Host "  SWAPPED order works - the portal values were reversed. Auto-correcting." -ForegroundColor Yellow
        $tmp = $tok; $tok = $key; $key = $tmp
    } else {
        throw @"
Both orders rejected by the easyDNS API (420 'Enhance Your Calm').
Either the pair is wrong/stale (someone regenerated after it was sent
to you - regenerating kills the old pair instantly) or the API is rate
limited (1 req/sec, 500/day, resets 12AM EST). Get the CURRENT pair
from the easyDNS Production Details page (REGENERATE if the Key was
never captured) and re-run this script. Nothing was stored.
"@
    }
}

Set-Secret -Name EasyDNS-Token -Secret $tok -Vault $VaultName
Set-Secret -Name EasyDNS-Key   -Secret $key -Vault $VaultName
Write-Host "  Secrets stored (verified working order)." -ForegroundColor Green

Write-Host "== [4/4] Let's Encrypt STAGING account ==" -ForegroundColor Cyan
Set-PAServer LE_STAGE   # staging first per runbook - no rate limits
$acct = Get-PAAccount -ErrorAction SilentlyContinue
if ($acct -and $acct.status -eq 'valid') {
    Write-Host "  Staging account already exists: $($acct.contact)"
} else {
    $mail = $ContactEmail
    while ([string]::IsNullOrWhiteSpace($mail)) {
        $mail = Read-Host "Contact email for Let's Encrypt account (e.g. certs@example.com)"
    }
    New-PAAccount -AcceptTOS -Contact "mailto:$mail"
}

Write-Host ""
Write-Host "DONE. NEXT: run 03-Test-StagingCert.ps1 (same account, same pwsh)." -ForegroundColor Green
Write-Host ""
Write-Host "TROUBLESHOOTING" -ForegroundColor Yellow
Write-Host "  'No such host is known' from Set-PAServer -> the server cannot resolve" -ForegroundColor Yellow
Write-Host "  acme-staging-v02.api.letsencrypt.org. Check DNS: Resolve-DnsName <name>," -ForegroundColor Yellow
Write-Host "  compare against -Server 8.8.8.8 to isolate internal DNS vs connectivity." -ForegroundColor Yellow
Write-Host "  'not valid JSON' from Set-PAServer -> HTTPS interception (proxy/FortiGate" -ForegroundColor Yellow
Write-Host "  web filter). Allow outbound 443 to both letsencrypt.org API hosts." -ForegroundColor Yellow
