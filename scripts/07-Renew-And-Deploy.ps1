# letsencrypt-recipe - https://github.com/Signal-Point-Technologies/letsencrypt-recipe
# Author : Andrew Cohen, Signal Point Technologies
# License: MIT
<#
=====================================================================
 PART 7 - THE production script: issue + renew + deploy, unattended
=====================================================================
 RUN BY   : The 'ACME-Renewal' scheduled task (registered by script 04),
            daily, as the service account, elevated (RunLevel Highest):
              pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass
                   -File "<scripts folder>\07-Renew-And-Deploy.ps1"
            Can also be run by hand for testing (elevated pwsh 7 as the
            service account).

 INVENTORY: the $CertHosts table lives in CertHosts.ps1 NEXT TO THIS
            SCRIPT (copy CertHosts.example.ps1 and edit). It is
            dot-sourced at startup; a missing file is a hard failure.

 WHAT IT DOES
   1. ISSUE  - refreshes every order's TRUE state from the CA
      (Get-PAOrder -List -Refresh, not the local cache), then acts on
      what it finds, via EasyDNSFix DNS-01. Sequential, with a pause
      between hosts (easyDNS allows 1 req/sec, 500/day).

        no order          -> place a new order and validate it
        pending           -> RESUME it: finish the DNS-01 challenges that
                             were never validated (logs which names are
                             still outstanding). NOT a fresh order - that
                             would discard in-flight work and burn a
                             new-order rate-limit slot.
        pending + expired -> the order's own window ran out; start fresh
        ready             -> validated but never finalized -> finalize
        processing        -> the CA is issuing -> resume and poll
        invalid           -> validation failed -> start a fresh order
        deactivated       -> start a fresh order
        valid + cert OK   -> skip; Submit-Renewal owns it
        valid + no cert   -> reissue (-Force; otherwise Posh-ACME only warns)
        valid + expired   -> reissue

      After every attempt it VERIFIES: a cert exists, is not already
      expired, and the order really reached 'valid'. An attempt that
      returns nothing is a failure, never a silent success. Once every
      host holds a good cert this whole stage is a no-op.

      ONE easyDNS credential pair (EasyDNS-Token / EasyDNS-Key in this
      profile's vault) is read once per run and used for every host -
      both zones are on the same easyDNS account. Posh-ACME also stores
      those args with each order, which is what Submit-Renewal uses, so
      renewals need no vault read at all.
   2. RENEW  - Set-PAServer LE_PROD, Submit-Renewal -AllOrders.
      (Posh-ACME only renews orders inside their ~60-day window, so
      most days this renews nothing and exits quickly.)
   3. DEPLOY - for every cert that was issued or ACTUALLY renewed, runs
      its Deploy hook from $CertHosts - for local IIS hosts that is:
        05-Import-CertToStore.ps1  (import + chain + remove superseded)
        06-Bind-IISCert.ps1        (rebind the site to the new thumbprint)
   4. REPORT - logs an inventory table (every host, NotAfter, days left,
      deploy state) on EVERY run, so a day where nothing renewed still
      proves the system ran and the fleet is healthy.

 LOGGING (see the LOGGING block further down for the details)
   Text log    C:\ProgramData\Posh-ACME-Renewal\renewal.log
               auto-rotated at 5 MB, 5 generations kept.
               Every run ends in exactly one grep-able line:
                 RESULT: OK   /   RESULT: FAILED
   Status file C:\ProgramData\Posh-ACME-Renewal\last-run.json
               machine-readable last-run summary + per-host expiry.
               Monitoring should alert on Result -ne 'OK' *and* on a
               StartedUtc older than ~36 h (task not running at all).
   Event log   Application / source 'ACME-Renewal'
               1000 = run OK, 1001 = run FAILED, 1002 = issued,
               1003 = renewed+deployed, 1004 = cert expiring soon.

 THE KINDS OF $CertHosts ENTRY
   Deploy = { ... }        automated end-to-end. Hook failure = FAILED.
   Deploy = { ... }  +  DeployNote = 'what is still manual'
                           the hook does PART of the job (e.g. mail: push
                           to the Exchange box's store, no binding). Runs
                           and must succeed, but logs a PARTIAL notice
                           every run so the remaining step stays visible.
   Deploy = $null    +  DeployPending = 'why'
                           cert is ISSUED AND RENEWED here, deploy is
                           still manual / a later runbook phase. Logged
                           as NOTICE, not a failure - deliberate, visible.
   (no entry at all)       a domain that renews with no $CertHosts entry
                           is logged WARNING + counted as FAILED, so a
                           silent gap still cannot hide.

 REMOTE STORE PUSHES (Push-CertToRemoteStore)
   An entry with PushTarget/PushSecrets gets its cert pushed into a
   REMOTE machine's cert store over WinRM, with the private key, and
   NOTHING is bound or restarted (e.g. an Exchange box, or an IIS host
   that is not the orchestrator).

   If the service account is a LOCAL user on this orchestrator it cannot
   authenticate to another machine as itself. Store a credential with
   local-admin rights on each target ONCE, as the service account:
     Set-Secret -Name <Host>-Cred -Secret (Get-Credential)
   Entries can list several secret names; they are tried in order, so a
   shared fallback (e.g. 'WinRM-Cred') needs storing only once:
     Set-Secret -Name WinRM-Cred -Secret (Get-Credential)

   Each target also needs WinRM reachable from here:
     Test-WSMan <target-fqdn>

   The PFX (which carries the private key) is copied to a temp folder on
   the remote box and deleted in a finally block, pass or fail. The push
   never passes -RemoveSuperseded: the target may still be bound to the
   previous cert, and removing it would break that service.

 EXCHANGE AUTO-BIND (Invoke-ExchangeBind, opt-in per entry)
   An Exchange entry with ExchangeBind = $true goes one step further
   after the push: revocation pre-check ON the Exchange server (fail
   closed), Enable-ExchangeCertificate -Services IIS,SMTP by thumbprint
   via the Microsoft.Exchange remote endpoint (Kerberos), re-pin of the
   listed receive connectors' TlsCertificateName to the new cert's real
   issuer/subject, then a TLS probe of 443 and 25/STARTTLS that must
   return the new thumbprint. The credential must be a DOMAIN account in
   Organization Management. See 09-Bind-ExchangeCert.ps1 for the manual
   / rollback equivalent and docs/RUNBOOK.md for the lessons behind it.

 SAN EDITS
   Changing an entry's Names takes effect on the next run: a valid cert
   whose SANs differ from Names is reissued (-Force). Preview with
   -WhatIfIssue (note: -WhatIfIssue still runs Submit-Renewal).

 DELIBERATELY EXCLUDED HOSTS
   Keep them in CertHosts.ps1 as COMMENTED-OUT entries with a one-line
   reason, so each omission reads as a decision, not an oversight.
   Typical reasons: the box is being retired; the platform issues its own
   certificate (two issuers for one name burn the Let's Encrypt
   duplicate-certificate limit).

 PROMOTING A PENDING HOST
   Prove its deploy by hand (runbook phase for that platform), then
   replace its DeployPending line with a Deploy scriptblock.

 WHEN SOMETHING BREAKS - SEND ONE FILE
   PS C:\> .\07-Renew-And-Deploy.ps1 -ExportDiagnostics
   Writes ONE text file (default C:\ProgramData\Posh-ACME-Renewal\
   acme-diagnostics-<stamp>.txt) holding: machine/user/elevation, script
   hashes, module + plugin state, ACME server + account, live order and
   authorization status, certificates, the local cert store, the
   scheduled task wiring, breaker state, last-run.json, and the tail of
   the renewal log. SECRETS ARE SCRUBBED - the live easyDNS token/key
   values, any stored WinRM password, Basic-auth headers and
   token/key/password-shaped strings are replaced with [REDACTED].
   It issues nothing, renews nothing, deploys nothing, and still works
   when the config is broken (each section degrades to a note).

 SELF-REPAIR - what it fixes ALONE, and what it will not
   FIXES (logged as 'REPAIRED:', never silent):
     - Mark-of-the-Web on scripts copied off a share
     - POSHACME_PLUGINS missing from a -NoProfile session
     - EasyDNSFix.ps1 missing or stale in the plugin folder (hash
       compared against the copy shipped beside this script)
     - orders left half-validated (resumed - see ISSUE above)
     - TRANSIENT issuance failures: one retry at a doubled DnsSleep
     - easyDNS 420 throttle: back off 120s, retry once
     - transient deploy/WinRM failures: one retry
   WILL NOT (needs a human, by design):
     - a missing or wrong credential - it cannot be invented, and
       retrying spends this hostname's failed-validation budget
     - swapped easyDNS token/key - a 420 on the first call is ambiguous
       between bad creds and throttling; guessing in a loop makes it
       worse. Run 02-Setup-Vault-Account.ps1, which verifies live.
     - a name genuinely absent from the easyDNS zone
     - anything requiring a binding decision (Exchange, IIS)

 CIRCUIT BREAKER - why a broken host goes quiet at the CA, not in alerts
   Consecutive per-host failures are tracked in host-health.json. After
   -BreakerThreshold (default 3) consecutive failed runs the script STOPS
   calling the CA for that host, because Let's Encrypt caps failed
   validations per hostname and repeating a deterministic failure every
   night can lock the name out. The host is STILL counted as FAILED, so
   alerting never goes quiet - only the wasted CA traffic stops. It is
   probed again every -BreakerRetryAfterHours (default 168) so a name
   fixed at the DNS end recovers on its own, and
   -ResetBreaker <fqdn> clears it immediately.

 TEST BY HAND
   PS C:\> .\07-Renew-And-Deploy.ps1                     # normal daily pass
   PS C:\> .\07-Renew-And-Deploy.ps1 -WhatIfIssue        # list what WOULD issue
   PS C:\> .\07-Renew-And-Deploy.ps1 -IssueOnly portal.example.com
           # issue exactly ONE host and nothing else - the safe way to do
           # the first production issuance of a new name onsite
   PS C:\> .\07-Renew-And-Deploy.ps1 -SkipIssue          # renew/deploy only
   PS C:\> .\07-Renew-And-Deploy.ps1 -ForceDeploy web01.example.com
           # re-runs the deploy hook for that domain WITHOUT renewing -
           # proves the import+bind path end-to-end any time

 FIRST-RUN TIMING
   N new names x (DnsSleep 120s + ACME work + 60s inter-host pause): six is
   roughly 20-30 minutes. The task's ExecutionTimeLimit is 2 hours, so it
   fits, but expect the first scheduled run to be long. Use
   -MaxIssuePerRun to spread it over several days if preferred.

 WHERE THE FILES LAND (for the hosts with no deploy hook yet)
   $env:LOCALAPPDATA\Posh-ACME\<acme-server>\<account-id>\<fqdn>\
   Get-PACertificate <fqdn> | Format-List *File*
=====================================================================
#>

[CmdletBinding()]
param(
    # Re-run the deploy hook for this domain without renewing (testing).
    [string]$ForceDeploy,

    # Restrict the issuance pass to these names only (everything else in
    # $CertHosts is skipped). Renewal still runs unless -SkipRenew.
    [string[]]$IssueOnly,

    # Skip the issuance pass entirely (pre-change behaviour: renew+deploy).
    [switch]$SkipIssue,

    # Skip Submit-Renewal (issue-only run).
    [switch]$SkipRenew,

    # Report what the issuance pass would do, issue nothing.
    [switch]$WhatIfIssue,

    # DNS propagation wait for DNS-01. Raise to 300 if validation times out.
    [int]$DnsSleep = 120,

    # Pause between issuances - easyDNS rate limits hard (1 req/sec, 500/day).
    [int]$IssuePauseSeconds = 60,

    # 0 = issue every host that needs one. Set e.g. 2 to spread the first
    # run over several days and stay well inside every rate limit.
    [int]$MaxIssuePerRun = 0,

    # Warn (and raise event 1004) when a cert has fewer days left than this.
    [int]$ExpiryWarnDays = 21,

    # Write ONE support bundle (config + logs + order state, secrets scrubbed)
    # and exit. Touches nothing. Use -DiagnosticsPath to choose the file.
    [switch]$ExportDiagnostics,
    [string]$DiagnosticsPath,

    # Retries for a TRANSIENT issuance failure only (DNS propagation, network).
    # Deterministic failures are never retried - retrying cannot fix them and
    # each attempt spends Let's Encrypt failed-validation budget.
    [int]$MaxRetries = 1,

    # Circuit breaker: after this many CONSECUTIVE failed runs for one host,
    # stop calling the CA for it. It still reports FAILED, so alerting stays
    # loud - it just stops burning rate limit every night on a broken name.
    [int]$BreakerThreshold = 3,

    # Even with the breaker open, probe the host again this often, so a name
    # that gets fixed at the DNS end recovers on its own.
    [int]$BreakerRetryAfterHours = 168,

    # Clear the breaker for these hosts ('*' for all) and attempt them again.
    [string[]]$ResetBreaker,

    # Skip the preflight checks (not recommended; they cost ~2 seconds).
    [switch]$SkipPreflight,

    # Skip the mechanical self-repairs (plugin install, Unblock-File, env var).
    [switch]$SkipSelfHeal,

    [string]$LogPath    = 'C:\ProgramData\Posh-ACME-Renewal\renewal.log',
    [string]$StatusPath = 'C:\ProgramData\Posh-ACME-Renewal\last-run.json',
    [string]$HealthPath = 'C:\ProgramData\Posh-ACME-Renewal\host-health.json',

    # Where the EasyDNSFix plugin is installed (script 01 uses this path too).
    [string]$PluginDir  = 'C:\ProgramData\Posh-ACME-Plugins',

    # Rotate the text log at this size, keeping $LogKeep generations.
    [int]$LogMaxMB = 5,
    [int]$LogKeep  = 5
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------
# pwsh 7 ONLY. Windows PowerShell 5.1 has TLS failures against the ACME
# and easyDNS APIs, and reads these UTF-8 files as ANSI. The scheduled
# task registered by 04 already uses pwsh.exe; this guard is for the
# hand-run case, where the 5.1 failure mode is a confusing wall of
# parse errors pointing at the plugin rather than at the real cause.
# ---------------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ''
    Write-Host 'This script requires PowerShell 7 - you are in Windows PowerShell ' -NoNewline -ForegroundColor Red
    Write-Host $PSVersionTable.PSVersion -ForegroundColor Red
    Write-Host ''
    Write-Host '  Type  pwsh  first, then re-run:' -ForegroundColor Yellow
    Write-Host '    pwsh' -ForegroundColor Yellow
    Write-Host "    .\$(Split-Path $PSCommandPath -Leaf) $($MyInvocation.UnboundArguments -join ' ')" -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Windows PowerShell 5.1 fails TLS against these APIs, and misreads' -ForegroundColor Yellow
    Write-Host 'the UTF-8 script files - which shows up as parse errors inside the' -ForegroundColor Yellow
    Write-Host 'EasyDNSFix plugin, far from the real cause.' -ForegroundColor Yellow
    Write-Host ''
    exit 2
}

# =====================================================================
# LOGGING
#   Three sinks, all best-effort except the text log:
#     Log()        -> renewal.log + stdout (stdout is captured by the
#                     scheduled task's own history, the file is the record)
#     Write-AcmeEvent -> Application event log, source 'ACME-Renewal'
#     the status JSON, written once at the end by Write-Status
#   Nothing in here may throw: a logging failure must never turn a
#   successful renewal into RESULT: FAILED.
# =====================================================================
$LogDir = Split-Path $LogPath
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# --- rotation: keep the log bounded, oldest generation drops off ---
try {
    $li = Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue
    if ($li -and $li.Length -gt ($LogMaxMB * 1MB)) {
        for ($n = $LogKeep - 1; $n -ge 1; $n--) {
            $src = "$LogPath.$n"; $dst = "$LogPath.$($n + 1)"
            if (Test-Path -LiteralPath $src) { Move-Item -LiteralPath $src -Destination $dst -Force }
        }
        Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force
    }
} catch { }

$EventSource = 'ACME-Renewal'
$script:EventSourceOk = $false
try {
    if ([System.Diagnostics.EventLog]::SourceExists($EventSource)) {
        $script:EventSourceOk = $true
    } else {
        # Needs elevation. The task runs RunLevel Highest, so this succeeds
        # on the first scheduled run; a non-elevated manual run just skips.
        [System.Diagnostics.EventLog]::CreateEventSource($EventSource, 'Application')
        $script:EventSourceOk = $true
    }
} catch { $script:EventSourceOk = $false }

function Log([string]$msg) {
    $line = "{0:s}  {1}" -f (Get-Date), $msg
    try { Add-Content -Path $LogPath -Value $line -ErrorAction Stop } catch { }
    Write-Host $line
}

function Write-AcmeEvent([string]$Message, [int]$EventId, [string]$Type = 'Information') {
    if (-not $script:EventSourceOk) { return }
    try {
        [System.Diagnostics.EventLog]::WriteEntry(
            $EventSource, $Message, [System.Diagnostics.EventLogEntryType]::$Type, $EventId)
    } catch { }
}

# Everything the run learned, serialised to $StatusPath at the end.
$RunStart = Get-Date
$Status = [ordered]@{
    Script      = '07-Renew-And-Deploy.ps1'
    StartedUtc  = $RunStart.ToUniversalTime().ToString('o')
    EndedUtc    = $null
    DurationSec = $null
    Machine     = $env:COMPUTERNAME
    RunAs       = "$env:USERDOMAIN\$env:USERNAME"
    PSVersion   = $PSVersionTable.PSVersion.ToString()
    Mode        = 'daily'
    Result      = 'UNKNOWN'      # OK | FAILED
    Issued      = @()
    Renewed     = @()
    Deployed    = @()
    Notices     = @()
    Failures    = @()
    Certs       = @()            # per-host expiry snapshot
}

function Write-Status([string]$Result) {
    $end = Get-Date
    $Status.Result      = $Result
    $Status.EndedUtc    = $end.ToUniversalTime().ToString('o')
    $Status.DurationSec = [int]($end - $RunStart).TotalSeconds
    try {
        ($Status | ConvertTo-Json -Depth 6) |
            Set-Content -Path $StatusPath -Encoding utf8 -ErrorAction Stop
    } catch {
        Log "WARNING: could not write status file '$StatusPath' - $($_.Exception.Message)"
    }
}

# =====================================================================
# PER-HOST HEALTH + CIRCUIT BREAKER
#   Consecutive failure counts persist across runs in $HealthPath. After
#   $BreakerThreshold consecutive failures a host is "open": the script
#   stops calling the CA for it (so a misconfigured name cannot spend
#   Let's Encrypt rate limit every night) but STILL reports it as FAILED,
#   so it never goes quiet. It is probed again every
#   $BreakerRetryAfterHours so a name fixed at the DNS end self-recovers.
# =====================================================================
$script:Health = @{}

function Import-HostHealth {
    try {
        if (Test-Path -LiteralPath $HealthPath) {
            $raw = Get-Content -LiteralPath $HealthPath -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($p in $raw.PSObject.Properties) {
                $script:Health[$p.Name] = @{
                    ConsecutiveFailures = [int]$p.Value.ConsecutiveFailures
                    LastError           = [string]$p.Value.LastError
                    LastErrorClass      = [string]$p.Value.LastErrorClass
                    LastFailureUtc      = [string]$p.Value.LastFailureUtc
                    LastSuccessUtc      = [string]$p.Value.LastSuccessUtc
                    LastAttemptUtc      = [string]$p.Value.LastAttemptUtc
                    RetryNotBefore      = [string]$p.Value.RetryNotBefore
                }
            }
        }
    } catch { Log "WARNING: could not read host health '$HealthPath' - $($_.Exception.Message)" }
}

function Export-HostHealth {
    try {
        ($script:Health | ConvertTo-Json -Depth 5) |
            Set-Content -Path $HealthPath -Encoding utf8 -ErrorAction Stop
    } catch { Log "WARNING: could not write host health '$HealthPath' - $($_.Exception.Message)" }
}

function Get-HostHealth([string]$Domain) {
    $k = $Domain.ToLower()
    if (-not $script:Health.ContainsKey($k)) {
        $script:Health[$k] = @{
            ConsecutiveFailures = 0; LastError = ''; LastErrorClass = ''
            LastFailureUtc = ''; LastSuccessUtc = ''; LastAttemptUtc = ''
            RetryNotBefore = ''
        }
    }
    return $script:Health[$k]
}

# Let's Encrypt usually says exactly when a rate limit clears, e.g.
#   "...already issued for this exact set of identifiers in the last
#    168h0m0s, retry after 2030-01-01T13:00:00Z"
# Honour that timestamp when it is there; otherwise assume 24h.
function Get-RateLimitRetryAfter([string]$Message) {
    if ($Message -match 'retry after\s+([0-9T:\-\.]+Z?)') {
        try { return ([datetimeoffset]::Parse($Matches[1])).UtcDateTime.ToString('o') } catch { }
    }
    if ($Message -match 'in the last\s+(\d+)h') {
        # Rolling window with no explicit time - wait a day and re-check.
        return (Get-Date).ToUniversalTime().AddHours(24).ToString('o')
    }
    return (Get-Date).ToUniversalTime().AddHours(24).ToString('o')
}

function Set-HostSuccess([string]$Domain) {
    $h = Get-HostHealth $Domain
    if ($h.ConsecutiveFailures -gt 0) {
        Log "  breaker reset for $Domain (was $($h.ConsecutiveFailures) consecutive failure(s))"
    }
    $h.ConsecutiveFailures = 0
    $h.LastError = ''; $h.LastErrorClass = ''
    $h.RetryNotBefore = ''
    $h.LastSuccessUtc = (Get-Date).ToUniversalTime().ToString('o')
    $h.LastAttemptUtc = $h.LastSuccessUtc
}

function Set-HostFailure([string]$Domain, [string]$Message, [string]$Class) {
    $h = Get-HostHealth $Domain
    $h.ConsecutiveFailures++
    $h.LastError = $Message
    $h.LastErrorClass = $Class
    $h.LastFailureUtc = (Get-Date).ToUniversalTime().ToString('o')
    $h.LastAttemptUtc = $h.LastFailureUtc

    # A CA rate limit is not a fault to retry past - it is a clock to wait
    # out. Park this host until the limit is known to have cleared, WITHOUT
    # waiting for the breaker threshold: every extra request while limited
    # can extend the window.
    if ($Class -eq 'CaRateLimit') {
        $h.RetryNotBefore = Get-RateLimitRetryAfter $Message
        $m = "RATE LIMITED: $Domain - the CA refused a new certificate. Not asking again until $($h.RetryNotBefore). Nothing is wrong with the config; the limit must simply expire."
        Log $m
        Write-AcmeEvent $m 1006 'Warning'
    }

    if ($h.ConsecutiveFailures -eq $BreakerThreshold) {
        $m = "BREAKER OPEN: $Domain has failed $($h.ConsecutiveFailures) consecutive runs. Pausing CA calls for it (still reported as FAILED). Last error [$Class]: $Message"
        Log $m
        Write-AcmeEvent $m 1005 'Warning'
    }
}

# Should we skip contacting the CA for this host? Returns a reason, or $null.
function Get-BreakerBlock([string]$Domain) {
    $h = Get-HostHealth $Domain

    # Rate-limit hold takes priority and applies from the FIRST occurrence.
    if ($h.RetryNotBefore) {
        try {
            $until = [datetime]::Parse($h.RetryNotBefore)
            if ((Get-Date).ToUniversalTime() -lt $until.ToUniversalTime()) {
                $mins = [int]($until.ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalMinutes
                return "CA rate limit in effect - not requesting again until $($h.RetryNotBefore) (about $mins min away). Last: $($h.LastError)"
            }
            Log "  rate-limit hold expired for $Domain - trying again"
            $h.RetryNotBefore = ''
        } catch { $h.RetryNotBefore = '' }
    }

    if ($h.ConsecutiveFailures -lt $BreakerThreshold) { return $null }
    if ($h.LastFailureUtc) {
        try {
            $age = (Get-Date).ToUniversalTime() - ([datetime]::Parse($h.LastFailureUtc)).ToUniversalTime()
            if ($age.TotalHours -ge $BreakerRetryAfterHours) {
                Log "  breaker probe: $Domain last failed $([int]$age.TotalHours)h ago (>= ${BreakerRetryAfterHours}h) - trying once"
                return $null
            }
        } catch { }
    }
    return "breaker open after $($h.ConsecutiveFailures) consecutive failures; last [$($h.LastErrorClass)]: $($h.LastError)"
}

# =====================================================================
# ERROR CLASSIFICATION
#   Decides whether a failure can possibly be fixed by trying again.
#   Getting this wrong is expensive: retrying a deterministic failure
#   spends Let's Encrypt's failed-validation budget for that hostname and
#   can lock the name out. When unsure, we do NOT retry.
# =====================================================================
function Get-IssueErrorClass([string]$Message) {
    if (-not $Message) { return 'Unknown' }
    $m = $Message.ToLower()

    # CA rate limit: retrying inside the same run is useless and harmful.
    if ($m -match 'ratelimited|too many (certificates|failed|orders)|rate limit|urn:ietf:params:acme:error:ratelimited') {
        return 'CaRateLimit'
    }
    # easyDNS throttle: short, self-clearing - one backoff retry is fine.
    if ($m -match 'enhance your calm|\b420\b|too many requests|\b429\b') {
        return 'DnsRateLimit'
    }
    # Cause cannot change by trying again.
    if ($m -match 'no zone found|nxdomain|unauthorized|rejectedidentifier|malformed|caa|account|credential|vault|not a pscredential|no readable pfx|not found next to this script|invalid.*key|access is denied') {
        return 'Deterministic'
    }
    # Plausibly self-clearing: propagation, network blips, CA hiccups.
    if ($m -match 'timed out|timeout|propagat|dns problem|servfail|connection|network|temporarily|serverinternal|unable to connect|the operation has timed out|502|503|504') {
        return 'Transient'
    }
    return 'Unknown'
}

# =====================================================================
# SELF-HEAL - mechanical, local, idempotent repairs only.
#   Everything here is safe to run every night and is logged as
#   REPAIRED: so it is never silent. Nothing that needs judgement (or a
#   password) belongs in this function.
# =====================================================================
function Invoke-SelfHeal {
    $repairs = 0

    # 1. Files copied off a network/OneDrive share carry Mark-of-the-Web.
    try {
        $blocked = @(Get-ChildItem -Path (Join-Path $PSScriptRoot '*.ps1') -ErrorAction SilentlyContinue |
                     Where-Object { Get-Item $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue })
        if ($blocked) {
            $blocked | Unblock-File -ErrorAction SilentlyContinue
            Log "REPAIRED: unblocked $($blocked.Count) script file(s) (Mark-of-the-Web)"
            $repairs++
        }
    } catch { }

    # 2. The plugin folder env var - a -NoProfile task can inherit a session
    #    without it.
    $pluginDir = $PluginDir
    if ($env:POSHACME_PLUGINS -ne $pluginDir) {
        $env:POSHACME_PLUGINS = $pluginDir
        Log "REPAIRED: set POSHACME_PLUGINS for this process"
        $repairs++
    }

    # 3. Keep EVERY installed copy of EasyDNSFix.ps1 identical to the one
    #    shipped beside this script.
    #
    #    THIS MUST RUN BEFORE Import-Module Posh-ACME. Posh-ACME parses every
    #    file in its own Plugins folder at import time, so ONE bad plugin file
    #    makes the whole module fail to load - and then nothing downstream,
    #    including this repair, can run at all. Pure file operations only: no
    #    Posh-ACME command is used here. (Get-Module -ListAvailable only reads
    #    the manifest, it does not load the module.)
    #
    #    The two locations are checked INDEPENDENTLY: a matching ProgramData
    #    copy must never mask a stale in-module copy - that combination has
    #    broken a production run before.
    $srcPlugin = Join-Path $PSScriptRoot 'EasyDNSFix.ps1'
    if (Test-Path -LiteralPath $srcPlugin) {
        $srcHash = (Get-FileHash -LiteralPath $srcPlugin -Algorithm SHA256).Hash

        $targets = @($pluginDir)
        try {
            $modBase = (Get-Module Posh-ACME -ListAvailable |
                        Sort-Object Version -Descending | Select-Object -First 1).ModuleBase
            if ($modBase) {
                $modPlugins = Join-Path $modBase 'Plugins'
                if (Test-Path -LiteralPath $modPlugins) { $targets += $modPlugins }
            }
        } catch { }

        $changed = $false
        foreach ($dir in $targets) {
            try {
                if (-not (Test-Path -LiteralPath $dir)) {
                    New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null
                }
                $dst = Join-Path $dir 'EasyDNSFix.ps1'
                $dstHash = if (Test-Path -LiteralPath $dst) {
                    (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash
                } else { '' }
                if ($srcHash -ne $dstHash) {
                    Copy-Item -LiteralPath $srcPlugin -Destination $dst -Force -ErrorAction Stop
                    $what = if ($dstHash) { 'refreshed STALE' } else { 'installed missing' }
                    Log "REPAIRED: $what EasyDNSFix.ps1 in $dir"
                    $repairs++
                    $changed = $true
                }
            } catch {
                Log "NOTE: could not refresh EasyDNSFix.ps1 in '$dir' ($($_.Exception.Message)). Run elevated, or re-run 01-Install-Prereqs.ps1."
            }
        }
        if ($changed -and (Get-Module Posh-ACME)) {
            Import-Module Posh-ACME -Force -ErrorAction SilentlyContinue
        }
    }

    if ($repairs -eq 0) { Log 'Self-heal: nothing to repair' }
}

# =====================================================================
# PREFLIGHT - fail in seconds with the exact missing thing, rather than
#   20 minutes in. Fatal checks throw BEFORE any CA contact; advisory
#   ones only warn, so a missing WinRM credential never blocks issuance.
# =====================================================================
function Test-Preflight {
    $fatal = @()

    # -- fatal: the sibling scripts every deploy path needs --
    foreach ($needed in '05-Import-CertToStore.ps1', '06-Bind-IISCert.ps1') {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $needed))) {
            $fatal += "$needed is not next to this script ($PSScriptRoot). Copy 05, 06, 07 and 08 into the SAME folder - 07 calls the others by relative path."
        }
    }

    # -- fatal: the DNS plugin --
    if (-not (Get-PAPlugin | Where-Object Name -eq 'EasyDNSFix')) {
        $fatal += "EasyDNSFix plugin not registered. Keep EasyDNSFix.ps1 next to this script (self-heal installs it), or re-run 01-Install-Prereqs.ps1 elevated. NEVER fall back to the built-in EasyDNS plugin."
    }

    # -- fatal: this profile's ACME state --
    $acct = $null
    try { $acct = Get-PAAccount } catch { }
    if (-not $acct) {
        $fatal += "No Posh-ACME account for $env:USERDOMAIN\$env:USERNAME on this ACME server. The task must run as the account that owns the vault and Posh-ACME state, or the account was never created (New-PAAccount -AcceptTOS -Contact 'mailto:<your-contact-email>')."
    }

    # -- fatal: the DNS credentials must at least EXIST (value read later) --
    foreach ($s in 'EasyDNS-Token', 'EasyDNS-Key') {
        $found = $null
        try { $found = Get-SecretInfo -Name $s -ErrorAction SilentlyContinue -WarningAction SilentlyContinue } catch { }
        if (-not $found) {
            $fatal += "Vault secret '$s' not found for $env:USERDOMAIN\$env:USERNAME. Re-run 02-Setup-Vault-Account.ps1 as the service account, and confirm the SecretStore is in unattended (no-password) mode."
        }
    }

    # -- advisory: elevation --
    try {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                   ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            Log 'PREFLIGHT WARN: not running elevated - certificate store import and event-log writes will fail. The scheduled task uses RunLevel Highest.'
        }
    } catch { }

    # -- advisory: remote push targets (never fatal - issuance must not be blocked) --
    foreach ($entry in $CertHosts) {
        if (-not $entry.PushTarget) { continue }
        $have = $false
        foreach ($n in $entry.PushSecrets) {
            try {
                if (Get-SecretInfo -Name $n -ErrorAction SilentlyContinue -WarningAction SilentlyContinue) { $have = $true; break }
            } catch { }
        }
        if (-not $have) {
            Log "PREFLIGHT WARN: no vault credential for $($entry.PushTarget) (looked for: $($entry.PushSecrets -join ', ')). $($entry.Domain) will still be ISSUED; only the store push will fail. Fix once with: Set-Secret -Name $($entry.PushSecrets[0]) -Secret (Get-Credential)"
        }
        try {
            Test-WSMan -ComputerName $entry.PushTarget -ErrorAction Stop | Out-Null
        } catch {
            # WSMan faults arrive as a wall of XML - keep the log readable.
            $reason = ($_.Exception.Message -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim()
            Log "PREFLIGHT WARN: WinRM not reachable at $($entry.PushTarget) - $reason. $($entry.Domain) will still be ISSUED; only the store push will fail."
        }
    }

    if ($fatal) {
        throw ("PREFLIGHT FAILED - " + ($fatal -join ' | '))
    }
    Log 'Preflight: OK'
}

# ---------------------------------------------------------------------
# =====================================================================
# DIAGNOSTICS EXPORT - one file, safe to send to someone for help.
#
#   Collects everything needed to diagnose a failure and SCRUBS secrets
#   from all of it: the live easyDNS token/key values, any stored WinRM
#   password, Basic-auth headers, and token/key/password-shaped strings.
#   Nothing in the normal log contains credentials, but the scrub runs
#   anyway - the whole point of this file is that it leaves the building.
# =====================================================================
function Protect-Secrets([string]$Text, [string[]]$Literals) {
    if (-not $Text) { return $Text }
    foreach ($lit in $Literals) {
        if ($lit -and $lit.Length -ge 6) {
            $Text = $Text -replace [regex]::Escape($lit), '[REDACTED]'
        }
    }
    $Text = $Text -replace '(?i)(Basic\s+)[A-Za-z0-9+/=]{16,}', '$1[REDACTED]'
    $Text = $Text -replace '(?i)((?:token|key|password|passwd|pwd|secret|pfxpass)\s*[:=]\s*)([^\s,;"'')}]{6,})', '$1[REDACTED]'
    return $Text
}

function Export-Diagnostics {
    param([string]$OutFile)

    if (-not $OutFile) {
        $stamp   = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $OutFile = Join-Path (Split-Path $LogPath) "acme-diagnostics-$stamp.txt"
    }

    # Live secret values, so they can be scrubbed out of anything collected.
    $literals = @()
    foreach ($n in 'EasyDNS-Token', 'EasyDNS-Key') {
        try {
            $v = Get-Secret -Name $n -AsPlainText -ErrorAction Stop -WarningAction SilentlyContinue
            if ($v) { $literals += $v }
        } catch { }
    }
    $credNames = @($CertHosts | ForEach-Object { $_.PushSecrets } | Where-Object { $_ } | Select-Object -Unique)
    foreach ($n in $credNames) {
        try {
            $c = Get-Secret -Name $n -ErrorAction Stop -WarningAction SilentlyContinue
            if ($c -is [pscredential]) { $literals += $c.GetNetworkCredential().Password }
        } catch { }
    }

    $out = [System.Collections.Generic.List[string]]::new()
    function Add-Section([string]$Title) {
        $out.Add(''); $out.Add(('=' * 72)); $out.Add("== $Title"); $out.Add(('=' * 72))
    }
    function Add-Safe([string]$Title, [scriptblock]$Body) {
        Add-Section $Title
        try {
            $r = & $Body
            if ($null -eq $r) { $out.Add('(nothing)') }
            else { $out.Add((($r | Out-String -Width 200).TrimEnd())) }
        } catch {
            $out.Add("(collection failed: $($_.Exception.Message))")
        }
    }

    $out.Add("ACME orchestrator diagnostics")
    $out.Add("Generated : $(Get-Date -Format s)")
    $out.Add("Machine   : $env:COMPUTERNAME")
    $out.Add("User      : $env:USERDOMAIN\$env:USERNAME")
    $out.Add("PowerShell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))")
    $out.Add("ScriptDir : $PSScriptRoot")
    try {
        $elev = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $out.Add("Elevated  : $elev")
    } catch { }
    $out.Add("NOTE: secrets are scrubbed from this file. Review before sending if you are unsure.")

    Add-Safe 'SCRIPT FILES (hash / size / modified)' {
        Get-ChildItem -Path (Join-Path $PSScriptRoot '*.ps1') |
            ForEach-Object {
                [pscustomobject]@{
                    Name     = $_.Name
                    KB       = [math]::Round($_.Length / 1KB, 1)
                    Modified = $_.LastWriteTime.ToString('s')
                    SHA256   = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.Substring(0, 16)
                }
            } | Format-Table -AutoSize
    }

    Add-Safe 'POSH-ACME MODULE + PLUGIN' {
        [pscustomobject]@{
            ModuleVersion     = (Get-Module Posh-ACME -ListAvailable | Sort-Object Version -Descending |
                                 Select-Object -First 1).Version.ToString()
            POSHACME_PLUGINS  = $env:POSHACME_PLUGINS
            POSHACME_HOME     = $env:POSHACME_HOME
            EasyDNSFixLoaded  = [bool](Get-PAPlugin | Where-Object Name -eq 'EasyDNSFix')
            InstalledPlugin   = if (Test-Path (Join-Path $PluginDir 'EasyDNSFix.ps1')) {
                                    (Get-FileHash (Join-Path $PluginDir 'EasyDNSFix.ps1') -Algorithm SHA256).Hash.Substring(0,16)
                                } else { 'NOT INSTALLED' }
        } | Format-List
    }

    Add-Safe 'ACME SERVER + ACCOUNT' {
        $srv = Get-PAServer
        $acc = Get-PAAccount
        [pscustomobject]@{
            Server        = $srv.location
            AccountId     = $acc.id
            AccountStatus = $acc.status
        } | Format-List
    }

    Add-Safe 'ORDERS (live status from the CA)' {
        Get-PAOrder -List -Refresh |
            Select-Object MainDomain, status, Plugin,
                          @{n='expires';e={$_.expires}},
                          @{n='RenewAfter';e={$_.RenewAfter}},
                          @{n='CertExpires';e={$_.CertExpires}} |
            Format-Table -AutoSize
    }

    Add-Safe 'AUTHORIZATIONS for orders not yet valid' {
        $rows = foreach ($o in (Get-PAOrder -List | Where-Object { $_.status -ne 'valid' })) {
            foreach ($a in (Get-PAAuthorization -AuthURLs $o.authorizations -ErrorAction SilentlyContinue)) {
                [pscustomobject]@{
                    Order = $o.MainDomain; Name = $a.fqdn
                    Status = $a.status; DNS01 = $a.DNS01Status; Expires = $a.expires
                }
            }
        }
        if ($rows) { $rows | Format-Table -AutoSize } else { 'all orders are valid' }
    }

    Add-Safe 'CERTIFICATES held by Posh-ACME' {
        Get-PACertificate -List |
            Select-Object Subject, NotAfter,
                          @{n='DaysLeft';e={[int]([datetime]$_.NotAfter - (Get-Date)).TotalDays}},
                          Thumbprint |
            Format-Table -AutoSize
    }

    Add-Safe 'LOCAL CERT STORE (inventory names)' {
        $names = $CertHosts.Domain
        Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop |
            Where-Object { $n = $_; $names | Where-Object { $n.DnsNameList.Unicode -contains $_ } } |
            Select-Object @{n='Name';e={$_.DnsNameList.Unicode -join ','}},
                          Thumbprint, NotAfter, HasPrivateKey |
            Format-Table -AutoSize
    }

    Add-Safe 'SCHEDULED TASK' {
        $t = Get-ScheduledTask -TaskName 'ACME-Renewal' -ErrorAction Stop
        $i = $t | Get-ScheduledTaskInfo
        [pscustomobject]@{
            State          = $t.State
            RunAs          = $t.Principal.UserId
            RunLevel       = $t.Principal.RunLevel
            LastRunTime    = $i.LastRunTime
            LastTaskResult = $i.LastTaskResult
            NextRunTime    = $i.NextRunTime
            Action         = ($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ; '
        } | Format-List
    }

    Add-Safe 'HOST HEALTH / CIRCUIT BREAKER' {
        if (Test-Path -LiteralPath $HealthPath) { Get-Content -LiteralPath $HealthPath -Raw }
        else { 'no health file yet' }
    }

    Add-Safe 'LAST RUN (last-run.json)' {
        if (Test-Path -LiteralPath $StatusPath) { Get-Content -LiteralPath $StatusPath -Raw }
        else { 'no status file yet' }
    }

    Add-Safe "RENEWAL LOG (last 1500 lines of $LogPath)" {
        if (Test-Path -LiteralPath $LogPath) {
            (Get-Content -LiteralPath $LogPath -Tail 1500) -join "`r`n"
        } else { 'no log file yet' }
    }

    Add-Safe 'ROTATED LOGS PRESENT' {
        Get-ChildItem -Path "$LogPath.*" -ErrorAction SilentlyContinue |
            Select-Object Name, @{n='KB';e={[math]::Round($_.Length/1KB,1)}}, LastWriteTime |
            Format-Table -AutoSize
    }

    $text = Protect-Secrets ($out -join "`r`n") $literals
    Set-Content -Path $OutFile -Value $text -Encoding utf8
    return $OutFile
}

# ---------------------------------------------------------------------
# Describe an order's DNS-01 authorizations: how many are validated and
# which names are not. Purely for the log - it must never throw, because
# it runs while deciding what to do, not while doing it.
# ---------------------------------------------------------------------
function Get-AuthSummary {
    param($Order)
    try {
        if (-not $Order.authorizations) { return 'no authorizations listed' }
        $auths = @(Get-PAAuthorization -AuthURLs $Order.authorizations -ErrorAction Stop)
        if (-not $auths) { return 'no authorizations returned' }
        $valid   = @($auths | Where-Object { $_.status -eq 'valid' })
        $pending = @($auths | Where-Object { $_.status -ne 'valid' })
        $summary = "$($valid.Count)/$($auths.Count) authorizations valid"
        if ($pending) {
            $detail = ($pending | ForEach-Object { "$($_.fqdn)=$($_.status)/dns01:$($_.DNS01Status)" }) -join ', '
            $summary += " - outstanding: $detail"
        }
        return $summary
    } catch {
        return "authorization status unavailable ($($_.Exception.Message))"
    }
}

# ---------------------------------------------------------------------
# Push a cert into a REMOTE machine's LocalMachine\My store, with its
# private key, over WinRM. STORE ONLY - it binds nothing and restarts
# nothing, so the target service is untouched.
#
# Deliberately does NOT pass -RemoveSuperseded: the target may still be
# bound to the previous certificate, and removing it would break that
# service. Old certs are cleaned up when the binding step is built.
#
# The PFX carries the private key, so the remote temp copy is deleted in
# a finally block whether the import passed or failed.
#
# $VaultSecretNames is tried in order, so a host can have its own credential or
# fall back to a shared one.
# ---------------------------------------------------------------------
function Push-CertToRemoteStore {
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string[]]$VaultSecretNames
    )

    # --- source PFX + its real password, straight from Posh-ACME ---
    $pa = Get-PACertificate -MainDomain $Domain -ErrorAction Stop
    $pfx = if ($pa.PfxFullChain -and (Test-Path $pa.PfxFullChain)) { $pa.PfxFullChain } else { $pa.PfxFile }
    if (-not $pfx -or -not (Test-Path $pfx)) { throw "Posh-ACME reported no readable PFX for '$Domain'." }
    $pfxPass = 'poshacme'
    if ($pa.PfxPass) {
        $pfxPass = if ($pa.PfxPass -is [securestring]) {
            [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pa.PfxPass))
        } else { [string]$pa.PfxPass }
    }

    # --- credentials for the remote box ---
    # The service account is a LOCAL user on this orchestrator, so it cannot
    # authenticate to another machine as itself. Store a credential with local
    # admin rights on the target ONCE, as the service account:
    #   Set-Secret -Name <name> -Secret (Get-Credential)
    $cred = $null
    foreach ($n in $VaultSecretNames) {
        try { $cred = Get-Secret -Name $n -ErrorAction Stop } catch { continue }
        if ($cred) { Log "  using vault credential '$n' for $Target"; break }
    }
    if (-not $cred) {
        throw "No credential for $Target in the vault (tried: $($VaultSecretNames -join ', ')). As the service account run: Set-Secret -Name $($VaultSecretNames[0]) -Secret (Get-Credential)  # an account with local admin on $Target"
    }
    if ($cred -isnot [pscredential]) {
        throw "Vault secret for $Target is not a PSCredential. Re-store it with: Set-Secret -Name $($VaultSecretNames[0]) -Secret (Get-Credential)"
    }

    $importer = Join-Path $PSScriptRoot '05-Import-CertToStore.ps1'
    if (-not (Test-Path $importer)) { throw "05-Import-CertToStore.ps1 not found next to this script - cannot push to $Target." }

    $session   = $null
    $remoteDir = $null
    try {
        $session = New-PSSession -ComputerName $Target -Credential $cred -ErrorAction Stop

        $remoteDir = Invoke-Command -Session $session -ScriptBlock {
            $p = Join-Path $env:TEMP ('acme-push-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $p -Force | Out-Null
            $p
        }

        Copy-Item -LiteralPath $pfx      -Destination $remoteDir -ToSession $session -Force
        Copy-Item -LiteralPath $importer -Destination $remoteDir -ToSession $session -Force

        # Verify by THUMBPRINT, never by name.
        # A target can already hold OTHER certificates carrying the same DNS
        # name (an internal-CA or self-signed one, often with a far later
        # expiry). Matching on name and taking the newest silently "confirms"
        # the wrong certificate - seen in production, where a long-lived
        # internal-CA cert masqueraded as the freshly pushed LE one.
        $expectedThumb = $pa.Thumbprint
        if (-not $expectedThumb) { throw "Posh-ACME did not report a thumbprint for '$Domain' - cannot verify the push." }

        $pfxName = Split-Path $pfx -Leaf
        $result = Invoke-Command -Session $session -ArgumentList $remoteDir, $pfxName, $pfxPass, $Domain, $expectedThumb -ScriptBlock {
            param($dir, $pfxName, $pass, $dom, $wantThumb)
            & (Join-Path $dir '05-Import-CertToStore.ps1') `
                -PfxFile (Join-Path $dir $pfxName) -PfxPass $pass `
                -InstallChain -Exportable -Confirm:$false | Out-Null

            $c = Get-ChildItem Cert:\LocalMachine\My |
                 Where-Object { $_.Thumbprint -eq $wantThumb } | Select-Object -First 1
            if (-not $c) {
                $also = @(Get-ChildItem Cert:\LocalMachine\My |
                          Where-Object { $_.DnsNameList.Unicode -contains $dom } |
                          ForEach-Object { "$($_.Thumbprint) (NotAfter $($_.NotAfter))" }) -join '; '
                throw ("Import ran but thumbprint $wantThumb is NOT in LocalMachine\My on $env:COMPUTERNAME." +
                       $(if ($also) { " Other certs present for '$dom': $also" } else { " No cert for '$dom' present at all." }))
            }
            if (-not $c.HasPrivateKey) {
                throw "Thumbprint $wantThumb is present on $env:COMPUTERNAME but has NO private key - the import did not carry the key."
            }
            $others = @(Get-ChildItem Cert:\LocalMachine\My |
                        Where-Object { $_.Thumbprint -ne $wantThumb -and $_.DnsNameList.Unicode -contains $dom } |
                        ForEach-Object { "$($_.Thumbprint) (NotAfter $($_.NotAfter))" })
            [pscustomobject]@{
                Thumbprint = $c.Thumbprint; NotAfter = $c.NotAfter
                Computer = $env:COMPUTERNAME; OtherCertsForName = $others
            }
        }

        Log "  $Target : VERIFIED $($result.Thumbprint) (NotAfter $($result.NotAfter)), private key present. NOT bound."
        if ($result.OtherCertsForName) {
            # Not an error, but the binding step must pick deliberately.
            Log "  NOTE: $Target also holds other cert(s) for '$Domain': $($result.OtherCertsForName -join '; ')"
            Log "        Bind by THUMBPRINT ($($result.Thumbprint)) so the wrong one cannot be picked up."
        }
        return $result
    } finally {
        if ($session -and $remoteDir) {
            try {
                Invoke-Command -Session $session -ArgumentList $remoteDir -ScriptBlock {
                    param($d) Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
                }
            } catch { }
        }
        if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------------
# EXCHANGE BIND (stage 2 of the mail path) - runs from THIS orchestrator.
#
# Called by an Exchange CertHosts entry's Deploy hook AFTER
# Push-CertToRemoteStore has verified the new cert + key in the Exchange
# server's LocalMachine\My, and only when the entry has ExchangeBind=$true.
#
#   1. Revocation pre-check ON the Exchange server (WinRM). Builds the
#      chain with online revocation. If the server cannot fetch the CA's
#      CRL (e.g. a firewall captive portal intercepting plain-HTTP egress)
#      Exchange would mark the cert RevocationCheckFailure - so we THROW
#      and bind nothing (fail closed).
#   2. Idempotence: TLS-probe 443 and 25/STARTTLS from here. If both
#      already serve the new thumbprint, done.
#   3. Enable-ExchangeCertificate -Thumbprint -Services IIS,SMTP via the
#      Exchange remote endpoint (http://<server>/PowerShell/, Kerberos).
#      NOT the snap-in: that needs a local logon (double-hop).
#   4. Verify by probing again. Exchange remote PowerShell DROPS the
#      Services property, so the wire is the only honest check anyway.
#
# Also re-pins each listed receive connector's TlsCertificateName to THIS
# cert's real issuer+subject. Default Frontend's Fqdn cannot be changed to
# the public name while AuthMechanism includes ExchangeServer, so
# name-based cert selection is impossible and a pin is required; rebuilding
# it from the live cert on every bind means a CA intermediate rotation can
# never leave it stale (stale pin = event 12014, no STARTTLS on port 25).
# Never touches IIS 444 / 8172, unlisted connectors, or old certs.
# ---------------------------------------------------------------------
function Read-SmtpReply([IO.StreamReader]$Reader) {
    # Multi-line replies use '250-...' until the last line '250 ...'.
    do { $l = $Reader.ReadLine() } while ($l -and $l.Length -ge 4 -and $l[3] -eq '-')
    return $l
}

function Get-ServedThumbprint {
    param([string]$Server, [int]$Port, [string]$Sni, [switch]$StartTls)
    $tcp = [Net.Sockets.TcpClient]::new()
    try {
        $iar = $tcp.BeginConnect($Server, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(15000)) { throw "connect to ${Server}:$Port timed out" }
        $tcp.EndConnect($iar)
        $stream = $tcp.GetStream(); $stream.ReadTimeout = 15000; $stream.WriteTimeout = 15000
        if ($StartTls) {
            $rd = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
            $wr = [IO.StreamWriter]::new($stream, [Text.Encoding]::ASCII, 1024, $true)
            $wr.NewLine = "`r`n"; $wr.AutoFlush = $true
            $null = Read-SmtpReply $rd
            $wr.WriteLine("EHLO $env:COMPUTERNAME"); $null = Read-SmtpReply $rd
            $wr.WriteLine('STARTTLS'); $r = Read-SmtpReply $rd
            if ($r -notmatch '^220') { throw "STARTTLS refused on ${Server}:$Port - '$r'" }
        }
        $ssl = [Net.Security.SslStream]::new($stream, $false, { $true })
        $ssl.AuthenticateAsClient($Sni)
        # Read RemoteCertificate here; assigning from inside the validation
        # callback does not propagate (separate runspace).
        $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate)
        $ssl.Dispose()
        return $cert.Thumbprint
    } finally { $tcp.Dispose() }
}

function Invoke-ExchangeBind {
    param(
        # Exchange server FQDN (WinRM + remote PowerShell endpoint).
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Thumbprint,
        [Parameter(Mandatory)][string]$Sni,
        [Parameter(Mandatory)][string[]]$VaultSecretNames,
        # Receive connectors (names only, no 'SERVER\' prefix) to re-pin.
        # Default: 'Default Frontend <SERVER>'. List EVERY FrontendTransport
        # connector bound to :25 - a custom connector with internal
        # RemoteIPRanges (e.g. an internal relay connector) wins for internal
        # senders, including this orchestrator's own port-25 probe. Left
        # unpinned it serves the self-signed server cert and verification
        # fails falsely.
        [string[]]$ReceiveConnector
    )
    $serverName = $Target.Split('.')[0]
    if (-not $ReceiveConnector) { $ReceiveConnector = @("Default Frontend $($serverName.ToUpper())") }

    $cred = $null
    foreach ($n in $VaultSecretNames) {
        try { $cred = Get-Secret -Name $n -ErrorAction Stop } catch { continue }
        if ($cred -is [pscredential]) { break } else { $cred = $null }
    }
    if (-not $cred) { throw "No PSCredential for $Target in the vault (tried: $($VaultSecretNames -join ', ')). It must be a DOMAIN account in Organization Management." }

    # --- 1. revocation pre-check, evaluated BY the Exchange server (its egress, not ours) ---
    $rev = Invoke-Command -ComputerName $Target -Credential $cred -ArgumentList $Thumbprint -ErrorAction Stop -ScriptBlock {
        param($t)
        $c  = Get-Item "Cert:\LocalMachine\My\$t" -ErrorAction Stop
        $ch = New-Object Security.Cryptography.X509Certificates.X509Chain $true
        $ch.ChainPolicy.RevocationMode      = 'Online'
        $ch.ChainPolicy.RevocationFlag      = 'EntireChain'
        $ch.ChainPolicy.UrlRetrievalTimeout = [timespan]::FromSeconds(30)
        $ok = $ch.Build($c)
        [pscustomobject]@{
            Ok      = $ok
            Status  = (@($ch.ChainStatus | ForEach-Object { "$($_.Status): $($_.StatusInformation.Trim())" }) -join '; ')
            Issuer  = $c.Issuer
            Subject = $c.Subject
        }
    }
    if (-not $rev.Ok) {
        throw "Revocation pre-check FAILED on $Target for $Thumbprint - NOT binding (Exchange would mark it RevocationCheckFailure). Chain: $($rev.Status). Usual cause: plain-HTTP egress to the CA's CRL host (e.g. *.lencr.org) blocked or intercepted by a captive portal."
    }
    Log "  $Target : revocation pre-check OK for $Thumbprint"

    # --- 2. already served on the wire? ---
    $probe = {
        $r = @{}
        foreach ($p in @(@{ Port = 443; Tls = $false }, @{ Port = 25; Tls = $true })) {
            try   { $r[$p.Port] = Get-ServedThumbprint -Server $Target -Port $p.Port -Sni $Sni -StartTls:$p.Tls }
            catch { $r[$p.Port] = "ERROR: $($_.Exception.Message)" }
        }
        $r
    }
    $before = & $probe
    Log "  $Target : serving before bind - 443=$($before[443])  25=$($before[25])"
    if ($before[443] -eq $Thumbprint -and $before[25] -eq $Thumbprint) {
        Log "  $Target : already serving $Thumbprint on 443 and 25 - no bind needed."
        return
    }

    # --- 3. bind via the Exchange remote endpoint ---
    $ex = $null
    $mod = $null
    try {
        $ex = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri "http://$Target/PowerShell/" `
                -Authentication Kerberos -Credential $cred -ErrorAction Stop
        $mod = Import-PSSession $ex -CommandName Enable-ExchangeCertificate, Get-ReceiveConnector, Set-ReceiveConnector `
                -Prefix AcmeEx -DisableNameChecking -AllowClobber -ErrorAction Stop
        Log "  $Target : Enable-ExchangeCertificate -Thumbprint $Thumbprint -Services IIS,SMTP (previous on 443: $($before[443]))"
        Enable-AcmeExExchangeCertificate -Server $serverName -Thumbprint $Thumbprint -Services 'IIS,SMTP' -Force -ErrorAction Stop

        # RE-PIN port 25. Default Frontend carries AuthMechanism ExchangeServer,
        # so its Fqdn MUST stay the server name (Set-ReceiveConnector -Fqdn
        # <public name> is refused - InvalidFqdnUnderExchangeServerAuth) and
        # name-based selection cannot be used. The pin is therefore rebuilt
        # from THIS cert's real issuer on every bind, so a CA intermediate
        # rotation can never leave it stale.
        $pin  = "<I>$($rev.Issuer)<S>$($rev.Subject)"
        $repinned = $false
        foreach ($rc in $ReceiveConnector) {
            $conn = "$serverName\$rc"
            $old  = (Get-AcmeExReceiveConnector $conn -ErrorAction Stop).TlsCertificateName
            if ("$old" -eq $pin) { continue }
            Log "  $Target : re-pinning '$conn' TlsCertificateName: '$old' -> '$pin'"
            # Save the old pin ON the Exchange server before changing it - rollback value.
            Invoke-Command -ComputerName $Target -Credential $cred -ArgumentList $conn, "$old" -ScriptBlock {
                param($c, $o)
                New-Item -ItemType Directory -Path C:\Temp -Force | Out-Null
                Add-Content -Path C:\Temp\rc-pin-history.txt -Value "$(Get-Date -Format s)  [$c]  $o"
            }
            Set-AcmeExReceiveConnector $conn -TlsCertificateName $pin -ErrorAction Stop
            $repinned = $true
        }
        if ($repinned) {
            # Make port 25 pick the new pin now instead of "within minutes".
            Invoke-Command -ComputerName $Target -Credential $cred -ScriptBlock {
                Restart-Service MSExchangeFrontEndTransport -ErrorAction Stop
            }
            Log "  $Target : MSExchangeFrontEndTransport restarted; old pin(s) saved to C:\Temp\rc-pin-history.txt"
        }
    } finally {
        if ($mod) { Remove-Module $mod -ErrorAction SilentlyContinue }
        if ($ex)  { Remove-PSSession $ex -ErrorAction SilentlyContinue }
    }

    # --- 4. verify on the wire (IIS rebind can take a few seconds) ---
    $after = $null
    foreach ($i in 1..6) {
        Start-Sleep -Seconds 10
        $after = & $probe
        if ($after[443] -eq $Thumbprint -and $after[25] -eq $Thumbprint) { break }
    }
    Log "  $Target : serving after bind - 443=$($after[443])  25=$($after[25])"
    $bad = @()
    if ($after[443] -ne $Thumbprint) { $bad += "443 serves $($after[443])" }
    if ($after[25]  -ne $Thumbprint) { $bad += "25/STARTTLS serves $($after[25]) (every :25 receive connector pinned? FrontEndTransport may need a restart)" }
    if ($bad) {
        throw "Bound $Thumbprint on $Target but verification failed: $($bad -join '; '). Rollback: Enable-ExchangeCertificate -Thumbprint $($before[443]) -Services IIS,SMTP -Force"
    }
    Log "  $Target : VERIFIED $Thumbprint served on 443 and 25/STARTTLS."
}

# ---------------------------------------------------------------------
# THE CERTIFICATE INVENTORY - one entry per host this orchestrator owns.
# Lives in CertHosts.ps1 NEXT TO THIS SCRIPT (copy CertHosts.example.ps1
# and edit). Dot-sourced here so the runner itself never needs editing.
#
#   Domain        primary name; also the Posh-ACME order name.
#   Names         full SAN list submitted to Let's Encrypt.
#   Deploy        scriptblock taking the domain; MUST THROW on failure.
#   DeployNote    set alongside Deploy when the hook only does PART of the
#                 job (e.g. a store push with no binding) - logged as a
#                 PARTIAL notice every run so the rest stays visible.
#   DeployPending set instead of Deploy when the cert is issued here but
#                 deployed elsewhere/by hand (logged NOTICE, not FAILED).
#   Hold          set to a reason to list the host WITHOUT issuing it.
#   PushTarget /  for remote store pushes: the WinRM target and the vault
#   PushSecrets   secret name(s) holding a PSCredential for it.
#   ExchangeBind  (Exchange only) $true = after the push, Invoke-ExchangeBind
#                 enables the cert for IIS,SMTP and re-pins the receive
#                 connectors. Leave $false until the first bind is proven.
#   ExchangeConnectors  (optional) receive connector names to re-pin.
#                 Default: 'Default Frontend <SERVER>' (short name).
# ---------------------------------------------------------------------
$CertHosts = $null
$inventoryFile = Join-Path $PSScriptRoot 'CertHosts.ps1'
try {
    if (-not (Test-Path -LiteralPath $inventoryFile)) {
        throw "Inventory file not found: $inventoryFile. Copy CertHosts.example.ps1 to CertHosts.ps1 next to this script and edit it."
    }
    . $inventoryFile
    if (-not $CertHosts -or @($CertHosts).Count -eq 0) {
        throw "CertHosts.ps1 loaded but defines no `$CertHosts entries."
    }
    foreach ($e in $CertHosts) {
        if (-not $e.Domain) { throw "CertHosts.ps1: an entry has no Domain." }
        if (-not $e.Names)  { $e.Names = @($e.Domain) }
    }
    $CertHosts = @($CertHosts)
} catch {
    $m = "RESULT: FAILED - $($_.Exception.Message)"
    Log $m
    Write-AcmeEvent $m 1001 'Error'
    $Status.Failures = @($_.Exception.Message)
    Write-Status 'FAILED'
    exit 1
}

$HostByDomain = @{}
foreach ($e in $CertHosts) { $HostByDomain[$e.Domain.ToLower()] = $e }

# Run header - who/where/what, so the log is self-describing.
Add-Content -Path $LogPath -Value (('=' * 72))
Log ("RUN START  host=$env:COMPUTERNAME  user=$env:USERDOMAIN\$env:USERNAME  " +
     "pwsh=$($PSVersionTable.PSVersion)  inventory=$($CertHosts.Count) host(s)")

$failures = @()
$deployed = @{}          # domains already deployed this run (issue -> don't deploy twice on renew)

# Run a host's deploy hook, or log why there isn't one.
function Invoke-DeployFor([string]$Domain, [string]$Reason) {
    $key = $Domain.ToLower()
    if ($deployed.ContainsKey($key)) { return }
    $deployed[$key] = $true

    $entry = $HostByDomain[$key]
    if (-not $entry) {
        $m = "WARNING: '$Domain' $Reason but has NO CertHosts entry - cert is issued but NOT deployed!"
        Log $m
        Write-AcmeEvent $m 1001 'Warning'
        $script:failures += "$Domain (no deploy hook)"
        return
    }
    if (-not $entry.Deploy) {
        $m = "NOTICE: '$Domain' $Reason - deploy is still manual: $($entry.DeployPending)"
        Log $m
        $script:Status.Notices += $m
        return
    }
    # A deploy touches the local store or a remote box over WinRM - never the
    # CA - so a transient failure here is safe to retry immediately.
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            Log "Deploying $Domain ..."
            & $entry.Deploy $Domain
            Log "Deploy OK: $Domain"
            $script:Status.Deployed += $Domain
            Write-AcmeEvent "Deployed $Domain ($Reason)." 1003 'Information'
            if ($entry.DeployNote) {
                # A hook that only does PART of the job says so, every time.
                $n = "NOTICE: $Domain deploy is PARTIAL - $($entry.DeployNote)"
                Log $n
                $script:Status.Notices += $n
            }
            return
        } catch {
            $msg   = $_.Exception.Message
            $class = Get-IssueErrorClass $msg
            if ($class -eq 'Transient' -and $attempt -le $MaxRetries) {
                Log "Deploy attempt $attempt failed for $Domain [$class]: $msg - retrying in 30s"
                Start-Sleep -Seconds 30
                continue
            }
            $m = "Deploy FAILED: $Domain [$class] - $msg"
            Log $m
            Write-AcmeEvent $m 1001 'Error'
            $script:failures += "$Domain ($msg)"
            return
        }
    }
}

# Per-run proof-of-life: every inventory host, its cert, days remaining.
function Write-InventoryReport {
    Log '--- certificate inventory ---'
    foreach ($entry in $CertHosts) {
        $d = $entry.Domain
        $crt = $null
        try { $crt = Get-PACertificate $d -ErrorAction SilentlyContinue } catch { }
        $mode = if ($entry.Hold)        { 'ON HOLD' }
                elseif ($entry.Deploy)  { if ($entry.DeployNote) { 'store-only' } else { 'auto-deploy' } }
                else                    { 'issue-only' }
        $hh   = Get-HostHealth $d
        $flag = if ($hh.ConsecutiveFailures -ge $BreakerThreshold) { '  [BREAKER OPEN]' }
                elseif ($hh.ConsecutiveFailures -gt 0)             { "  [$($hh.ConsecutiveFailures) consecutive failure(s)]" }
                else { '' }
        if ($crt) {
            $days = [int]([datetime]$crt.NotAfter - (Get-Date)).TotalDays
            Log (("  {0,-26} {1,-11} NotAfter {2:yyyy-MM-dd} ({3} days)  thumb {4}" -f
                 $d, $mode, $crt.NotAfter, $days, $crt.Thumbprint) + $flag)
            $script:Status.Certs += [ordered]@{
                Domain = $d; Mode = $mode
                NotAfter = ([datetime]$crt.NotAfter).ToUniversalTime().ToString('o')
                DaysLeft = $days; Thumbprint = $crt.Thumbprint
                ConsecutiveFailures = $hh.ConsecutiveFailures
                BreakerOpen = ($hh.ConsecutiveFailures -ge $BreakerThreshold)
                LastError = $hh.LastError
            }
            if ($days -lt $ExpiryWarnDays) {
                $m = "EXPIRY WARNING: $d has $days day(s) left and has not renewed yet."
                Log $m
                Write-AcmeEvent $m 1004 'Warning'
            }
        } else {
            Log (("  {0,-26} {1,-11} NO CERT" -f $d, $mode) + $flag)
            $script:Status.Certs += [ordered]@{
                Domain = $d; Mode = $mode; NotAfter = $null; DaysLeft = $null; Thumbprint = $null
                ConsecutiveFailures = $hh.ConsecutiveFailures
                BreakerOpen = ($hh.ConsecutiveFailures -ge $BreakerThreshold)
                LastError = $hh.LastError
            }
        }
    }
    Log '-----------------------------'
}

try {
    # -----------------------------------------------------------------
    # STAGE 0a - SELF-HEAL, BEFORE the module is imported.
    #
    # Order matters and is not cosmetic: Posh-ACME parses every file in
    # its Plugins folder at import time, so a single stale/corrupt plugin
    # file makes Import-Module itself throw. Repairing after the import
    # would mean the repair can never run in exactly the case that needs
    # it. Self-heal touches files only - it calls no Posh-ACME command.
    # (Seen in production: a stale in-module EasyDNSFix.ps1 broke the
    # import under Windows PowerShell 5.1 before self-heal was reached.)
    # -----------------------------------------------------------------
    if ($SkipSelfHeal) { Log 'Self-heal skipped (-SkipSelfHeal)' } else { Invoke-SelfHeal }

    if ($env:POSHACME_PLUGINS -ne $PluginDir) { $env:POSHACME_PLUGINS = $PluginDir }
    try {
        Import-Module Posh-ACME -ErrorAction Stop
    } catch {
        throw "Import-Module Posh-ACME failed: $($_.Exception.Message)  --  If this points at a file under \Plugins\, that plugin file is corrupt. Confirm EasyDNSFix.ps1 sits next to this script (self-heal copies it into place), and re-run 01-Install-Prereqs.ps1 elevated if it persists."
    }

    # Last-resort plugin check in case self-heal could not repair it.
    if (-not (Get-PAPlugin | Where-Object Name -eq 'EasyDNSFix')) {
        Import-Module Posh-ACME -Force
    }

    Set-PAServer LE_PROD
    Log "ACME server: $((Get-PAServer).location)"

    Import-HostHealth
    if ($ResetBreaker) {
        foreach ($k in @($script:Health.Keys)) {
            if ($ResetBreaker -contains '*' -or $ResetBreaker -contains $k) {
                $script:Health[$k].ConsecutiveFailures = 0
                Log "Breaker manually reset for $k"
            }
        }
        Export-HostHealth
    }

    # -----------------------------------------------------------------
    # -ExportDiagnostics: write the support bundle and stop.
    # -----------------------------------------------------------------
    if ($ExportDiagnostics) {
        $Status.Mode = 'diagnostics'
        Log 'Collecting diagnostics (no issuance, no renewal, no deploy)'
        $file = Export-Diagnostics -OutFile $DiagnosticsPath
        Log "Diagnostics written to: $file"
        Write-Host ''
        Write-Host '=======================================================================' -ForegroundColor Cyan
        Write-Host " DIAGNOSTICS BUNDLE READY - secrets scrubbed" -ForegroundColor Cyan
        Write-Host "   $file" -ForegroundColor Yellow
        Write-Host ' Send that ONE file. It contains config, order state, breaker state,' -ForegroundColor Cyan
        Write-Host ' the last run summary and the tail of the renewal log.' -ForegroundColor Cyan
        Write-Host '=======================================================================' -ForegroundColor Cyan
        Write-Status 'OK'
        exit 0
    }

    # -----------------------------------------------------------------
    # STAGE 0b - PREFLIGHT: fail in seconds, not 20 minutes in
    # -----------------------------------------------------------------
    if ($SkipPreflight) { Log 'Preflight skipped (-SkipPreflight)' } else { Test-Preflight }

    # -----------------------------------------------------------------
    # -ForceDeploy: manual deploy test, nothing else runs.
    # -----------------------------------------------------------------
    if ($ForceDeploy) {
        $Status.Mode = 'force-deploy'
        Log "MANUAL: forcing deploy hook for $ForceDeploy (no issue, no renewal)"
        Invoke-DeployFor $ForceDeploy 'was force-deployed'
        $Status.Failures = $failures
        if ($failures) {
            Log ("RESULT: FAILED - " + ($failures -join '; '))
            Write-AcmeEvent ("Force-deploy FAILED: " + ($failures -join '; ')) 1001 'Error'
            Write-Status 'FAILED'
            exit 1
        }
        Log 'RESULT: OK'
        Write-AcmeEvent "Force-deploy OK: $ForceDeploy" 1000 'Information'
        Write-Status 'OK'
        exit 0
    }

    # -----------------------------------------------------------------
    # STAGE 1 - ISSUE anything in the inventory that has no valid cert
    # -----------------------------------------------------------------
    if ($SkipIssue) {
        Log 'Issue pass skipped (-SkipIssue)'
    } else {
        # Guard FIRST: with no account, Get-PAOrder throws a cryptic
        # "No ACME account configured" from inside Posh-ACME.
        if (-not (Get-PAAccount)) {
            throw "No Posh-ACME account on LE_PROD for this profile ($env:USERDOMAIN\$env:USERNAME). Either the task is running as the wrong account (state lives in the service account's profile) or the account was never created: New-PAAccount -AcceptTOS -Contact 'mailto:<your-contact-email>'"
        }

        # Pull CURRENT order state from the CA, not the local cache. An order
        # that was left half-validated shows its real status only after this.
        try {
            $orders = @(Get-PAOrder -List -Refresh)
        } catch {
            Log "WARNING: could not refresh order state from the CA ($($_.Exception.Message)); falling back to cached state"
            $orders = @(Get-PAOrder -List)
        }
        $now  = Get-Date
        $todo = @()

        foreach ($entry in $CertHosts) {
            $d = $entry.Domain
            if ($IssueOnly -and ($IssueOnly -notcontains $d)) { continue }

            # ---- ON HOLD: deliberately not issued yet. Listed in the
            # ---- inventory so it cannot be forgotten, but no CA call and
            # ---- NOT a failure - the run still reports OK.
            if ($entry.Hold -and -not ($IssueOnly -contains $d)) {
                Log "HOLD: $d - $($entry.Hold)"
                Log "  issue it anyway with: .\07-Renew-And-Deploy.ps1 -IssueOnly $d   (or remove the Hold line in `$CertHosts)"
                continue
            }

            $order = $orders | Where-Object { $_.MainDomain -eq $d } | Select-Object -First 1

            # ---- circuit breaker: stop spending CA budget on a host that has
            # ---- failed every run. Still reported as FAILED below, so this
            # ---- goes quiet at the CA, never in the alerting.
            $blocked = Get-BreakerBlock $d
            if ($blocked -and -not ($order -and $order.status -eq 'valid')) {
                Log "SKIPPED $d - $blocked"
                Log "  override with: .\07-Renew-And-Deploy.ps1 -ResetBreaker $d   (only once the cause is fixed or the limit has cleared)"
                $failures += "$d (skipped: $blocked)"
                continue
            }

            # ---- no order at all: a brand new name ----
            if (-not $order) {
                $todo += @{ Entry = $entry; Why = 'no order yet'; Force = $false }
                continue
            }

            # Has the order's own window (for finishing validation) run out?
            $orderExpired = $false
            if ($order.expires) {
                try { $orderExpired = ([datetimeoffset]::Parse($order.expires) -lt [datetimeoffset]::Now) } catch { }
            }

            switch ($order.status) {

                # Authorizations not all validated yet. New-PACertificate picks
                # the order back up and runs Submit-ChallengeValidation, so the
                # right move is to resume it, NOT to -Force a fresh order (that
                # would throw away in-flight work and burn a new-order slot).
                'pending' {
                    if ($orderExpired) {
                        $todo += @{ Entry = $entry; Why = "pending order EXPIRED $($order.expires) - starting a fresh order"; Force = $true }
                    } else {
                        $todo += @{ Entry = $entry; Why = "order pending - $(Get-AuthSummary $order); completing validation"; Force = $false }
                    }
                }

                # Validated but never finalized - just needs the finalize + download.
                'ready' {
                    $todo += @{ Entry = $entry; Why = 'order validated but not finalized - finalizing'; Force = $false }
                }

                # CA is issuing; resuming polls it to completion.
                'processing' {
                    $todo += @{ Entry = $entry; Why = 'order finalizing at the CA - resuming'; Force = $false }
                }

                # Validation failed, or the order was deactivated. Posh-ACME
                # starts a fresh order for these on its own - no -Force needed.
                { $_ -in 'invalid', 'deactivated' } {
                    $todo += @{ Entry = $entry; Why = "order status '$($order.status)' ($(Get-AuthSummary $order)) - starting a fresh order"; Force = $false }
                }

                'valid' {
                    $crt = $null
                    try { $crt = Get-PACertificate $d -ErrorAction SilentlyContinue } catch { }
                    if (-not $crt) {
                        # Order completed at the CA but the files are gone locally.
                        # -Force is required or Posh-ACME just warns and does nothing.
                        $todo += @{ Entry = $entry; Why = 'order valid but no cert on disk - reissuing'; Force = $true }
                    } elseif ([datetime]$crt.NotAfter -le $now) {
                        $todo += @{ Entry = $entry; Why = "cert expired $($crt.NotAfter) - reissuing"; Force = $true }
                    } elseif (Compare-Object @($crt.AllSANs | ForEach-Object { $_.ToLower() } | Sort-Object -Unique) `
                                            @($entry.Names | ForEach-Object { $_.ToLower() } | Sort-Object -Unique)) {
                        # SAN list in CertHosts changed since issuance. Submit-Renewal
                        # renews the OLD name set forever, so reissue with the new one.
                        # (Without this check a SAN edit silently never takes effect.)
                        $todo += @{ Entry = $entry; Why = "SAN mismatch - cert has [$($crt.AllSANs -join ', ')], CertHosts wants [$($entry.Names -join ', ')] - reissuing"; Force = $true }
                    }
                    # otherwise: healthy cert - Submit-Renewal owns it from here.
                }

                default {
                    $todo += @{ Entry = $entry; Why = "unrecognised order status '$($order.status)' - reissuing"; Force = $true }
                }
            }
        }

        if ($MaxIssuePerRun -gt 0 -and $todo.Count -gt $MaxIssuePerRun) {
            $deferred = ($todo | Select-Object -Skip $MaxIssuePerRun | ForEach-Object { $_.Entry.Domain }) -join ', '
            Log "Issuance capped at $MaxIssuePerRun this run; deferred to a later run: $deferred"
            $todo = @($todo | Select-Object -First $MaxIssuePerRun)
        }

        if ($todo.Count -eq 0) {
            Log "Issue pass: nothing to issue - every inventory host holds a valid cert"
        } elseif ($WhatIfIssue) {
            $Status.Mode = 'whatif-issue'
            foreach ($t in $todo) {
                Log "WHATIF: would issue $($t.Entry.Domain) [$($t.Entry.Names -join ', ')] - $($t.Why)"
            }
        } else {
            Log "Issue pass: $($todo.Count) host(s) need a cert"

            # ONE set of easyDNS credentials serves EVERY host in the inventory.
            # All zones are assumed to live under the same easyDNS account, and
            # the vault belongs to this profile, so these are read once here
            # and reused for every issuance below. Posh-ACME also
            # stores them with each order, which is what Submit-Renewal uses
            # later - so renewals need no vault read at all.
            try {
                $pArgs = @{
                    EDToken = (Get-Secret EasyDNS-Token -AsPlainText)
                    EDKey   = (Get-Secret EasyDNS-Key   -AsPlainText)
                }
                Log "easyDNS credentials loaded from the vault (EasyDNS-Token / EasyDNS-Key) - shared by all $($todo.Count) issuance(s) this run"
            } catch {
                throw "Cannot read easyDNS creds from the vault as $env:USERDOMAIN\$env:USERNAME. The task user MUST be the account that ran 02-Setup-Vault-Account.ps1, and the SecretStore must be in unattended (no-password) mode. Inner: $($_.Exception.Message)"
            }

            $i = 0
            foreach ($t in $todo) {
                $i++
                $d = $t.Entry.Domain
                $action = if ($t.Force) { 'Reissuing' } else { 'Issuing/resuming' }

                $attempt   = 0
                $sleepNow  = $DnsSleep
                $succeeded = $false
                while ($true) {
                    $attempt++
                    Log "$action $d [$($t.Entry.Names -join ', ')] - $($t.Why) (attempt $attempt, DnsSleep ${sleepNow}s)"
                    try {
                        # Plugin + PluginArgs are passed on EVERY attempt, resume
                        # included: that also repairs any order still pointing at the
                        # broken built-in 'EasyDNS' plugin.
                        $newArgs = @{
                            Domain     = $t.Entry.Names
                            Plugin     = 'EasyDNSFix'
                            PluginArgs = $pArgs
                            DnsSleep   = $sleepNow
                        }
                        if ($t.Force) { $newArgs.Force = $true }
                        $new = New-PACertificate @newArgs

                        # VERIFY, don't assume. New-PACertificate can return nothing
                        # (e.g. it decided the order was already complete) - that is
                        # not success, and must not be logged as issued.
                        if (-not $new) { $new = Get-PACertificate $d -ErrorAction SilentlyContinue }
                        if (-not $new) {
                            throw "issuance returned no certificate and none is on disk - order did not complete"
                        }
                        if ([datetime]$new.NotAfter -le (Get-Date)) {
                            throw "issuance produced an already-expired certificate (NotAfter $($new.NotAfter))"
                        }
                        $post = Get-PAOrder -MainDomain $d -Refresh -ErrorAction SilentlyContinue
                        if ($post -and $post.status -ne 'valid') {
                            throw "order status is still '$($post.status)' after issuance - validation did not complete ($(Get-AuthSummary $post))"
                        }

                        Log "Issued OK: $d (NotAfter $($new.NotAfter), thumbprint $($new.Thumbprint))"
                        $Status.Issued += $d
                        Set-HostSuccess $d
                        Write-AcmeEvent "Issued certificate for $d (NotAfter $($new.NotAfter))." 1002 'Information'
                        Invoke-DeployFor $d 'was newly issued'
                        $succeeded = $true
                        break

                    } catch {
                        $msg   = $_.Exception.Message
                        $class = Get-IssueErrorClass $msg

                        # Retry ONLY what a retry can actually fix. A deterministic
                        # failure re-tried just spends this hostname's Let's Encrypt
                        # failed-validation budget for nothing.
                        $retry = $false
                        if ($attempt -le $MaxRetries) {
                            if ($class -eq 'Transient') {
                                $sleepNow = [Math]::Min($sleepNow * 2, 300)
                                Log "  [$class] $msg"
                                Log "  retrying with a longer DNS wait (${sleepNow}s)"
                                $retry = $true
                            } elseif ($class -eq 'DnsRateLimit') {
                                Log "  [$class] $msg"
                                Log '  easyDNS throttled us; backing off 120s then retrying once'
                                Start-Sleep -Seconds 120
                                $retry = $true
                            }
                        }
                        if ($retry) { continue }

                        $why = switch ($class) {
                            'CaRateLimit'   { 'CA rate limit - NOT retrying; retrying would make it worse' }
                            'Deterministic' { 'cause cannot change by retrying - NOT retrying (this needs a human)' }
                            'Unknown'       { 'unrecognised error - NOT retrying, to protect the rate limit' }
                            default         { 'retries exhausted' }
                        }
                        $m = "Issue FAILED: $d [$class] after $attempt attempt(s) - $msg  ($why)"
                        Log $m
                        Write-AcmeEvent $m 1001 'Error'
                        $failures += "$d (issue failed [$class]: $msg)"
                        Set-HostFailure $d $msg $class
                        break
                    }
                }
                if ($i -lt $todo.Count) {
                    Log "Pausing ${IssuePauseSeconds}s between issuances (easyDNS rate limit)"
                    Start-Sleep -Seconds $IssuePauseSeconds
                }
            }
        }
    }

    # -----------------------------------------------------------------
    # STAGE 2 - RENEW everything already inside its renewal window
    # -----------------------------------------------------------------
    $renewed = @()
    # -WhatIfIssue is a PREVIEW: never renew (a renewal would deploy, which
    # for Exchange means a bind, connector re-pin and transport restart).
    if ($WhatIfIssue -and -not $SkipRenew) {
        Log 'Skipping Submit-Renewal (-WhatIfIssue is preview-only)'
        $SkipRenew = $true
    }
    if ($SkipRenew) {
        Log 'Skipping Submit-Renewal (-SkipRenew)'
    } else {
        Log "Running Submit-Renewal -AllOrders"
        # Returns a PACertificate per order that actually renewed; $null when none.
        $renewed = @(Submit-Renewal -AllOrders -Verbose 4>> $LogPath)
        Log "Renewed this run: $($renewed.Count)"
        $Status.Renewed = @($renewed | ForEach-Object { $_.MainDomain } | Where-Object { $_ })
    }

    # -----------------------------------------------------------------
    # STAGE 3 - DEPLOY every cert that changed
    # -----------------------------------------------------------------
    foreach ($cert in $renewed) {
        $domain = $cert.MainDomain
        if (-not $domain) { continue }
        Invoke-DeployFor $domain 'renewed'
    }

    # -----------------------------------------------------------------
    # STAGE 4 - REPORT: proof-of-life even on a do-nothing day
    # -----------------------------------------------------------------
    Write-InventoryReport

    Export-HostHealth
    $Status.Failures = $failures
    if ($failures) {
        Log ("RESULT: FAILED - " + ($failures -join '; '))
        Log "For help: .\07-Renew-And-Deploy.ps1 -ExportDiagnostics   (writes one scrubbed file to send)"
        Write-AcmeEvent ("ACME run FAILED: " + ($failures -join '; ')) 1001 'Error'
        Write-Status 'FAILED'
        exit 1
    }
    Log ("RESULT: OK - issued $($Status.Issued.Count), renewed $($Status.Renewed.Count), deployed $($Status.Deployed.Count), notices $($Status.Notices.Count)")
    Write-AcmeEvent ("ACME run OK. Issued $($Status.Issued.Count), renewed $($Status.Renewed.Count), deployed $($Status.Deployed.Count). " +
                     "Inventory: $(($Status.Certs | ForEach-Object { "$($_.Domain)=$($_.DaysLeft)d" }) -join ', ')") 1000 'Information'
    Write-Status 'OK'
    exit 0

} catch {
    $m = "RESULT: FAILED - $($_.Exception.Message)"
    Log $m
    Log "  at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)"
    Log "For help: .\07-Renew-And-Deploy.ps1 -ExportDiagnostics   (writes one scrubbed file to send)"
    $failures += $_.Exception.Message
    $Status.Failures = $failures
    try { Export-HostHealth } catch { }
    Write-AcmeEvent $m 1001 'Error'
    Write-Status 'FAILED'
    exit 1
}
