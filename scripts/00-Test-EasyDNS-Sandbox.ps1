# letsencrypt-recipe - https://github.com/Signal-Point-Technologies/letsencrypt-recipe
# Author : Andrew Cohen, Signal Point Technologies
# License: MIT
<#
=====================================================================
 PART 0 (optional) - easyDNS SANDBOX end-to-end API test
=====================================================================
 RUN AS   : Anyone, any shell (PS 5.1 or pwsh 7), no admin needed
 PURPOSE  : Prove this machine can reach the easyDNS API and perform
            the full cycle Posh-ACME needs: auth -> list records ->
            add TXT -> delete TXT. Run it ON THE ORCHESTRATOR to rule
            out firewall/proxy interference on the server's path.

 SANDBOX creds are throwaway test credentials generated in the easyDNS
 portal (Sandbox Details page). They only work against
 sandbox.rest.easydns.net and never touch public DNS. Pass them with
 -Token/-Key; nothing is baked into this script.

 VERIFIED FACTS (established from live testing against the API):
   - Auth = HTTP Basic "token:key". Portal labels are correct.
   - A 420 "Enhance Your Calm" body (served as HTTP 200!) means
     rate limit exceeded *OR WRONG CREDENTIALS* - identical error.
   - Rate limits: 1 request/second, 500/day, daily reset 12AM EST.
   - Delete endpoint = DELETE /zones/records/<domain>/<id>

 EXAMPLE
   PS C:\> .\00-Test-EasyDNS-Sandbox.ps1 -Token '<sandbox-token>' -Key '<sandbox-key>' -Zone 'example.com'

 EXPECTED OUTPUT: four PASS lines. Any 420 body on the FIRST call
 with known-good sandbox creds = something on this network path is
 mangling the request (proxy stripping the Authorization header is
 the usual suspect). Confirm by running the same creds+code from
 another machine.
=====================================================================
#>

param(
    [Parameter(Mandatory)][string]$Token,
    [Parameter(Mandatory)][string]$Key,
    # A zone that exists in the sandbox account (sandbox mirrors production zone data)
    [Parameter(Mandatory)][string]$Zone,
    [string]$ApiBase = 'https://sandbox.rest.easydns.net'
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${Token}:${Key}"))
$h = @{ Authorization = $auth }
$testHost = '_acme-test'
$fail = $false

function Assert-NotCalmError($resp, $step) {
    if ($resp.error.code -eq 420) {
        Write-Host "FAIL [$step]: got 420 'Enhance Your Calm' (= rate limited OR creds not accepted)" -ForegroundColor Red
        Write-Host "  Body: $($resp | ConvertTo-Json -Compress)" -ForegroundColor Red
        $script:fail = $true
        return $false
    }
    return $true
}

Write-Host "Testing from: $env:COMPUTERNAME as $env:USERNAME -> $ApiBase" -ForegroundColor Cyan

# --- 1. LIST ---
$r = Invoke-RestMethod "$ApiBase/zones/records/all/$Zone`?format=json" -Headers $h
if (Assert-NotCalmError $r 'LIST') {
    Write-Host "PASS [1/4] LIST: $(($r.data | Measure-Object).Count) records in $Zone" -ForegroundColor Green
}
Start-Sleep -Seconds 3   # stay under 1 req/sec with margin

# --- 2. ADD TXT ---
if (-not $fail) {
    $body = @{ domain=$Zone; host=$testHost; ttl=300; prio=0; type='TXT'; rdata="pipeline-test-$PID" } | ConvertTo-Json
    $r = Invoke-RestMethod -Method PUT -Uri "$ApiBase/zones/records/add/$Zone/txt?format=json" -Headers $h -ContentType 'application/json' -Body $body
    if ((Assert-NotCalmError $r 'ADD') -and $r.status -eq 201) {
        $recId = $r.data.id
        Write-Host "PASS [2/4] ADD: TXT $testHost.$Zone created (id $recId)" -ForegroundColor Green
    } else { $fail = $true }
    Start-Sleep -Seconds 3
}

# --- 3. VERIFY present ---
if (-not $fail) {
    $r = Invoke-RestMethod "$ApiBase/zones/records/all/$Zone`?format=json" -Headers $h
    $rec = $r.data | Where-Object { $_.host -eq $testHost }
    if ($rec) {
        Write-Host "PASS [3/4] VERIFY: record visible via API" -ForegroundColor Green
    } else {
        Write-Host "FAIL [3/4] VERIFY: record not found after add" -ForegroundColor Red; $fail = $true
    }
    Start-Sleep -Seconds 3
}

# --- 4. DELETE (cleanup) ---
if (-not $fail) {
    foreach ($id in @($rec.id)) {
        $r = Invoke-RestMethod -Method DELETE -Uri "$ApiBase/zones/records/$Zone/$id`?format=json" -Headers $h
        Start-Sleep -Seconds 2
    }
    Write-Host "PASS [4/4] DELETE: test record removed" -ForegroundColor Green
}

Write-Host ""
if ($fail) {
    Write-Host "RESULT: FAIL - see above. If these sandbox creds passed on another machine," -ForegroundColor Red
    Write-Host "the difference is this machine's network path (proxy/SSL inspection)." -ForegroundColor Red
    exit 1
} else {
    Write-Host "RESULT: ALL PASS - this machine talks to the easyDNS API correctly." -ForegroundColor Green
    Write-Host "NEXT: regenerate the PRODUCTION token in the easyDNS portal, store the new" -ForegroundColor Yellow
    Write-Host "pair via 02-Setup-Vault-Account.ps1 (or Set-Secret), then run" -ForegroundColor Yellow
    Write-Host "03-Test-StagingCert.ps1 -Hosts '<one-name-per-zone>'  (ONE attempt)." -ForegroundColor Yellow
}
