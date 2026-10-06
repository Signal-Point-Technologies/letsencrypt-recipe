# letsencrypt-recipe - https://github.com/Signal-Point-Technologies/letsencrypt-recipe
# Author : Andrew Cohen, Signal Point Technologies
# License: MIT
<#
=====================================================================
 PART 9 - Bind a store-imported cert to Exchange services (IIS, SMTP)
=====================================================================
 RUN ON   : the Exchange server itself (e.g. exch01.corp.example.net),
            NOT the orchestrator.
 RUN AS   : a DOMAIN account in Organization Management, ELEVATED.
 SHELL    : Windows PowerShell 5.1 ONLY. The Exchange snap-in does not
            load in pwsh 7. (Note this is the opposite of script 07,
            which is pwsh 7 only.)

 WHY THIS SCRIPT EXISTS
   With ExchangeBind = $false, 07-Renew-And-Deploy.ps1 pushes the mail
   cert into this box's LocalMachine\My and STOPS - no binding, so a
   renewal can never disturb mail flow unattended.

   Once the cert IS bound, though, store-only becomes a time bomb: at
   the next 90-day renewal a new cert lands in the store SERVICE-
   DISABLED, Exchange keeps using the old one, and everything breaks
   at expiry - port 25, OWA, and hybrid mail flow at once. The normal
   fix is ExchangeBind = $true in CertHosts.ps1 (07 then binds, re-pins
   and verifies from the orchestrator). This script is the MANUAL /
   ROLLBACK tool: first cutover, emergencies, or binding an older cert
   back. It can also run from a scheduled task on the Exchange box.

 WHY THE SNAP-IN AND NOT RemoteExchange.ps1
   Connect-ExchangeServer builds an implicit remoting session even on
   the local box. That is a second hop to AD (ADInvalidCredentialException
   under a network logon) AND it silently strips the Services and
   CertificateDomains properties this script needs. Add-PSSnapin runs
   IN-PROCESS: no hop, and the properties are intact.

 WHAT IT DOES
   1. Finds the newest cert in LocalMachine\My that
        - has subject CN=<Domain>            (or -Thumbprint, explicit)
        - was issued by <IssuerMatch>        (default: Let's Encrypt)
        - is not self-signed, not expired, not yet valid
        - has a private key
        - covers EVERY name in -RequiredNames
   2. If that cert is already enabled for all -Services, exits 0 quietly.
      (Idempotent - safe to run every day.)
   3. Otherwise runs Enable-ExchangeCertificate -Services <...> -Force
   4. Re-reads and verifies the binding actually took
   5. Logs, writes an Application event, and returns a non-zero exit
      code on failure so existing ACME monitoring picks it up

 WHAT IT DELIBERATELY DOES NOT DO
   - Never touches the Exchange Back End binding (port 444) or WMSvc
     (8172). Those must keep the Exchange self-signed cert.
     Enable-ExchangeCertificate -Services IIS only rebinds the
     Default Web Site, which is what we want.
   - Never sets or clears TlsCertificateName on any connector. The
     Default Frontend connector's Fqdn cannot be changed to the public
     name (ExchangeServer auth), so port 25 needs a pin. After binding
     by hand, re-pin EVERY :25 receive connector yourself:
       Set-ReceiveConnector "<SERVER>\Default Frontend <SERVER>" `
         -TlsCertificateName "<I>$($c.Issuer)<S>$($c.Subject)"
     building the string from the NEW cert ($c), never typed by hand -
     a stale issuer string (CA intermediate rotation) = event 12014 and
     no STARTTLS. 07's Invoke-ExchangeBind does this automatically.
     Do NOT just clear the pin: Exchange then selects the self-signed
     server cert and the internet sees it.
   - Never removes the superseded certificate.

 EVENT LOG
   Source 'ACME-Renewal' in the Application log, same as 07, so the
   existing alert on event 1001 / Error needs no change.
     1010 Information - bound a new certificate
     1011 Information - already bound, no action
     1001 Error       - could not bind (ALERTS)

 EXAMPLES
   # What the scheduled task runs:
   PS C:\> .\09-Bind-ExchangeCert.ps1

   # Preview without changing anything - ALWAYS do this first:
   PS C:\> .\09-Bind-ExchangeCert.ps1 -WhatIf

   # Pin an exact cert (rollback, or a non-LE cert):
   PS C:\> .\09-Bind-ExchangeCert.ps1 -Thumbprint <thumbprint>

   # Cut back to a commercial-CA cert in an emergency:
   PS C:\> .\09-Bind-ExchangeCert.ps1 -Thumbprint <old thumbprint> -IssuerMatch '<CA name>'

 ROLLBACK
   Re-run with -Thumbprint <old thumbprint>. This script prints the
   currently-bound thumbprint before it switches - keep that line.
   The old cert stays in the store; nothing here removes it.
=====================================================================
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    # Primary name. Used to find the cert and as a required SAN.
    [string]$Domain = 'mail.example.com',

    # Every one of these must be on the cert or it is refused. Keep in
    # sync with the Names entry for this domain in CertHosts.ps1.
    [string[]]$RequiredNames = @('mail.example.com', 'smtp.example.com'),

    # Substring match against the issuer DN. Guards against binding a
    # self-signed or unexpected-CA cert that happens to carry the name -
    # a long-lived Exchange store often holds several certs for one name.
    [string]$IssuerMatch = "Let's Encrypt",

    # Skip discovery and use exactly this cert.
    [string]$Thumbprint,

    [string[]]$Services = @('IIS', 'SMTP'),

    # Exchange updates the Default Web Site binding itself. Only set this
    # if a bind appears not to take effect for OWA/ECP.
    [switch]$RestartIIS,

    [string]$LogPath = 'C:\ProgramData\ACME\09-bind-exchange.log'
)

$ErrorActionPreference = 'Stop'
$EventSource = 'ACME-Renewal'

# --------------------------------------------------------------- logging
$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$script:EventSourceOk = $false
try {
    if ([System.Diagnostics.EventLog]::SourceExists($EventSource)) {
        $script:EventSourceOk = $true
    } else {
        # Needs elevation. The scheduled task runs RunLevel Highest, so this
        # succeeds on the first scheduled run; a non-elevated manual run
        # just logs to file instead.
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

function Fail([string]$msg) {
    Log "ERROR: $msg"
    Write-AcmeEvent "Exchange cert bind FAILED on $($env:COMPUTERNAME): $msg" 1001 'Error'
    exit 1
}

# --------------------------------------------------------------- preflight
Log "=== 09-Bind-ExchangeCert starting on $env:COMPUTERNAME as $env:USERDOMAIN\$env:USERNAME ==="

if ($PSVersionTable.PSVersion.Major -ge 6) {
    Fail "This script is Windows PowerShell 5.1 ONLY - the Exchange snap-in will not load in pwsh $($PSVersionTable.PSVersion). (Script 07 is the opposite: pwsh 7 only.)"
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "Not elevated. Run as Administrator (scheduled task: RunLevel Highest)."
}

# In-process snap-in. Do NOT switch this to RemoteExchange.ps1 /
# Connect-ExchangeServer - see the header.
if (-not (Get-PSSnapin -Name Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction SilentlyContinue)) {
    try {
        Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction Stop
        Log "loaded Exchange snap-in in-process"
    } catch {
        Fail "Could not load the Exchange snap-in: $($_.Exception.Message). Run this ON the Exchange server, as a domain account in Organization Management, from a local logon (not inside Enter-PSSession - that is a Kerberos double hop)."
    }
}

# --------------------------------------------------------------- find cert
function Test-CoversNames {
    param($Cert, [string[]]$Names)
    $sans = @($Cert.DnsNameList | ForEach-Object { "$($_.Unicode)".ToLower() })
    foreach ($n in $Names) {
        if ($sans -notcontains $n.ToLower()) { return $false }
    }
    return $true
}

$now = Get-Date

if ($Thumbprint) {
    $tp = $Thumbprint -replace '[^0-9A-Fa-f]', ''
    $candidate = Get-Item "Cert:\LocalMachine\My\$tp" -ErrorAction SilentlyContinue
    if (-not $candidate) { Fail "No certificate with thumbprint $tp in LocalMachine\My." }
    Log "using explicitly supplied thumbprint $tp"
} else {
    $all = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop)

    $candidates = @($all | Where-Object {
        $_.Subject   -like "*CN=$Domain*"     -and
        $_.Issuer    -like "*$IssuerMatch*"   -and
        $_.Issuer    -ne   $_.Subject         -and   # reject self-signed
        $_.HasPrivateKey                      -and
        $_.NotAfter  -gt $now                 -and
        $_.NotBefore -le $now                 -and
        (Test-CoversNames -Cert $_ -Names $RequiredNames)
    } | Sort-Object NotAfter -Descending)

    if ($candidates.Count -eq 0) {
        # Say WHY, loudly. The usual cause is a renewal that issued with
        # the wrong SAN set, which is silent otherwise.
        $near = @($all | Where-Object { $_.Subject -like "*CN=$Domain*" })
        Log "no usable certificate found. Certs carrying CN=$Domain in the store:"
        foreach ($c in ($near | Sort-Object NotAfter -Descending)) {
            Log ("   {0}  exp {1:yyyy-MM-dd}  key={2}  issuer={3}  sans={4}" -f `
                $c.Thumbprint.Substring(0,8), $c.NotAfter, $c.HasPrivateKey,
                (($c.Issuer -split ',')[0]), (($c.DnsNameList | ForEach-Object { "$($_.Unicode)" }) -join ','))
        }
        Fail "No valid '$IssuerMatch' certificate for $Domain covering all of: $($RequiredNames -join ', '). Check the Names entry in CertHosts.ps1 and re-issue."
    }

    $candidate = $candidates[0]
    if ($candidates.Count -gt 1) {
        Log "$($candidates.Count) usable candidates; taking the one with the latest NotAfter"
    }
}

Log ("candidate {0}  subject={1}  issuer={2}  exp={3:yyyy-MM-dd}  sans={4}" -f `
    $candidate.Thumbprint, $candidate.Subject, (($candidate.Issuer -split ',')[0]),
    $candidate.NotAfter, (($candidate.DnsNameList | ForEach-Object { "$($_.Unicode)" }) -join ','))

# Re-verify even on the -Thumbprint path. An explicit thumbprint is a
# human decision, but binding a keyless or expired cert breaks Exchange
# just as thoroughly.
if (-not $candidate.HasPrivateKey) { Fail "Certificate $($candidate.Thumbprint) has no private key." }
if ($candidate.NotAfter -le $now)  { Fail "Certificate $($candidate.Thumbprint) expired $($candidate.NotAfter)." }

# --------------------------------------------------------------- current state
$exCert = Get-ExchangeCertificate -Thumbprint $candidate.Thumbprint -ErrorAction SilentlyContinue
if (-not $exCert) { Fail "Exchange cannot see certificate $($candidate.Thumbprint)." }

$currentSvcs = @("$($exCert.Services)" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'None' })
$missing     = @($Services | Where-Object { $currentSvcs -notcontains $_ })

# For the rollback line, and to warn about ambiguity.
$boundNow = @(Get-ExchangeCertificate | Where-Object { "$($_.Services)" -match 'SMTP|IIS' })
Log "currently service-enabled certs:"
foreach ($b in $boundNow) {
    Log ("   {0}  [{1}]  exp {2:yyyy-MM-dd}  {3}" -f `
        $b.Thumbprint.Substring(0,8), $b.Services, $b.NotAfter, (($b.Subject -split ',')[0]))
}

if ($missing.Count -eq 0) {
    Log "already enabled for $($Services -join ',') - nothing to do."
    Write-AcmeEvent ("Exchange cert already bound on $($env:COMPUTERNAME): {0} [{1}] exp {2:yyyy-MM-dd}." -f `
        $candidate.Thumbprint, $exCert.Services, $candidate.NotAfter) 1011 'Information'
    exit 0
}

Log "needs enabling for: $($missing -join ', ')  (currently: $(if($currentSvcs){$currentSvcs -join ','}else{'None'}))"

# --------------------------------------------------------------- bind
$target = ($Services + $currentSvcs | Select-Object -Unique) -join ','

if (-not $PSCmdlet.ShouldProcess("$($candidate.Thumbprint) on $env:COMPUTERNAME", "Enable-ExchangeCertificate -Services $target")) {
    Log "WHATIF: would run Enable-ExchangeCertificate -Thumbprint $($candidate.Thumbprint) -Services $target -Force"
    exit 0
}

try {
    Enable-ExchangeCertificate -Thumbprint $candidate.Thumbprint -Services $target -Force -ErrorAction Stop
    Log "Enable-ExchangeCertificate returned OK"
} catch {
    Fail "Enable-ExchangeCertificate failed: $($_.Exception.Message)"
}

# --------------------------------------------------------------- verify
Start-Sleep -Seconds 2
$after     = Get-ExchangeCertificate -Thumbprint $candidate.Thumbprint -ErrorAction Stop
$afterSvcs = @("$($after.Services)" -split ',' | ForEach-Object { $_.Trim() })
$stillMissing = @($Services | Where-Object { $afterSvcs -notcontains $_ })

if ($stillMissing.Count -gt 0) {
    Fail "Bind did not take. $($candidate.Thumbprint) still missing: $($stillMissing -join ', ') (reports: $($after.Services))"
}

if ($RestartIIS) {
    Log "restarting IIS (-RestartIIS)"
    & iisreset /noforce | Out-Null
}

$msg = "Exchange cert BOUND on $($env:COMPUTERNAME): {0} [{1}] exp {2:yyyy-MM-dd}, issuer {3}." -f `
        $candidate.Thumbprint, $after.Services, $candidate.NotAfter, (($candidate.Issuer -split ',')[0])
Log $msg
Log "ROLLBACK: .\09-Bind-ExchangeCert.ps1 -Thumbprint <one of the previously-bound thumbprints logged above>"
Write-AcmeEvent $msg 1010 'Information'

# Superseded certs are left in place on purpose - removing one that a
# service is still using is how you turn a renewal into an outage.
Log "=== done ==="
exit 0
