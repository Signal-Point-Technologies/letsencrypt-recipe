# letsencrypt-recipe

Unattended Let's Encrypt certificate rotation for a mixed Windows fleet, driven from one Windows orchestrator with [Posh-ACME](https://github.com/rmbolger/Posh-ACME) and **DNS-01** via easyDNS.

One box issues every cert, keeps the DNS API credentials in a DPAPI-bound vault, renews daily, deploys each cert with a per-host hook, and writes a log line you can alert on. Built and hardened in production; every odd rule in here is a scar.

- **CA:** Let's Encrypt (staging first, then production)
- **Challenge:** DNS-01 (no inbound ports; works for internal-only names)
- **DNS provider:** easyDNS via the bundled `EasyDNSFix` plugin (the built-in Posh-ACME plugin is broken against easyDNS's API, see below)
- **Targets:** local IIS, remote IIS / Exchange over WinRM (store push, optional Exchange auto-bind), anything else as "issue here, install by hand"

> Adapting to another DNS provider: swap `-Plugin EasyDNSFix` / the `EDToken`/`EDKey` args for the Posh-ACME plugin of your provider in scripts `03`, `07`, `08` and drop `EasyDNSFix.ps1`. Everything else is provider-neutral.

## Layout

```text
scripts/
  00-Test-EasyDNS-Sandbox.ps1   optional network-path test against the easyDNS sandbox
  01-Install-Prereqs.ps1        pwsh 7, modules, EasyDNSFix plugin install     (admin, elevated)
  02-Setup-Vault-Account.ps1    vault + DNS creds (live-verified) + LE account (SERVICE ACCOUNT, pwsh 7)
  03-Test-StagingCert.ps1       staging cert per zone - the go/no-go gate      (SERVICE ACCOUNT, pwsh 7)
  04-Register-RenewalTask.ps1   daily scheduled task that runs 07              (admin, elevated)
  05-Import-CertToStore.ps1     PFX -> LocalMachine\My (+chain, +key ACL)       (admin, elevated)
  06-Bind-IISCert.ps1           point an IIS https binding at a thumbprint     (admin, on the web server)
  07-Renew-And-Deploy.ps1       THE daily runner: issue + renew + deploy + report
  08-AcmeDoctor.ps1             health check + repair
  09-Bind-ExchangeCert.ps1      manual / rollback Exchange bind, run ON the Exchange box (5.1 + snap-in)
  CertHosts.example.ps1         inventory template -> copy to CertHosts.ps1 (git-ignored)
  EasyDNSFix.ps1                corrected Posh-ACME DNS plugin for easyDNS
docs/
  RUNBOOK.md                    phased rollout plan, per-platform deploy patterns, rollback, verification, moving the orchestrator
  MS-TUNNEL-GATEWAY.md          Microsoft Tunnel Gateway on Linux: acme.sh + mst-cli, tested step by step
```

## Quick start (fresh orchestrator)

```powershell
# 0. Pick a SERVICE ACCOUNT. The vault and ALL Posh-ACME state live in that
#    profile. The account that runs 02 is the account the task MUST run as.

# 1. Elevated console (5.1 or 7), from scripts\:
Set-ExecutionPolicy RemoteSigned -Scope Process -Force
.\01-Install-Prereqs.ps1

# 2. As the SERVICE ACCOUNT, in pwsh 7:
pwsh
.\02-Setup-Vault-Account.ps1 -VerifyZone example.com -ContactEmail certs@example.com
#    prompts for the easyDNS Token + Key, verifies them LIVE, auto-corrects a swapped pair

# 3. Same account, same pwsh - one representative name per zone:
.\03-Test-StagingCert.ps1 -Hosts 'web01.example.com','vpn1.example.net'
#    every zone must PASS before production

# 4. Production account (same account, same pwsh):
Set-PAServer LE_PROD
New-PAAccount -AcceptTOS -Contact 'mailto:certs@example.com'

# 5. Inventory:
Copy-Item .\CertHosts.example.ps1 .\CertHosts.ps1     # then edit
.\07-Renew-And-Deploy.ps1 -WhatIfIssue                 # shows what WOULD issue, issues nothing
.\07-Renew-And-Deploy.ps1 -IssueOnly web01.example.com # first production issuance, ONE name

# 6. Elevated pwsh - register the daily task:
.\04-Register-RenewalTask.ps1 -TaskUser 'CONTOSO\svc-acme'
Start-ScheduledTask -TaskName 'ACME-Renewal'           # smoke test
Get-Content C:\ProgramData\Posh-ACME-Renewal\renewal.log -Tail 30
```

## What script 07 does every night

1. **Issue** - refreshes every order's **true state from the CA** (`Get-PAOrder -List -Refresh`, not the local cache) and acts on it. Sequential, 60 s between hosts (easyDNS = 1 req/sec, 500/day). A no-op once every host holds a good cert.
2. **Renew** - `Submit-Renewal -AllOrders`. Posh-ACME only touches orders inside their renewal window, so most nights this renews nothing.
3. **Deploy** - runs the `Deploy` hook of every domain that was issued or renewed this run (at most once per run).
4. **Report** - logs the whole inventory with NotAfter + days remaining, so a night where nothing changed still proves the system ran.

### Half-finished orders resume; they don't restart

| Order state | What the script does |
| --- | --- |
| *no order* | place a new order and validate it |
| `pending` | **resume** - finish the DNS-01 challenges that never validated, log which names are outstanding |
| `pending`, past `expires` | the order's own window ran out - start fresh |
| `ready` | validated but never finalized - finalize |
| `processing` | the CA is issuing - resume and poll |
| `invalid` / `deactivated` | validation failed - start a fresh order |
| `valid`, cert healthy | skip - `Submit-Renewal` owns it |
| `valid`, cert missing on disk | reissue with `-Force` (without it Posh-ACME only warns) |
| `valid`, cert expired | reissue |
| `valid`, cert SANs differ from `Names` | reissue (`-Force`) with the new SAN set |

Every attempt is **verified, not assumed**: afterwards the script confirms a cert exists, is not expired, and the order really reached `valid`. `New-PACertificate` returning nothing is a failure, never a silent success.

### The `$CertHosts` inventory (`CertHosts.ps1`)

| Entry | Meaning | On failure |
| --- | --- | --- |
| `Deploy = { ... }` | automated end to end | `RESULT: FAILED` |
| `Deploy = { ... }` + `DeployNote` | the hook does **part** of the job (push to a remote store, no binding) | `RESULT: FAILED`, plus a `PARTIAL` notice every run |
| `DeployPending = 'why'` | cert **is** issued and renewed here; deploy is manual | `NOTICE`, run stays OK |
| `Hold = 'why'` | **not issued** - no CA call, still listed | `HOLD` line, run stays OK |
| *no entry* | a domain renewed that nobody owns | `RESULT: FAILED ... (no deploy hook)` |

`Hold` overrides everything except `-IssueOnly <that host>`. See `CertHosts.example.ps1` for the five patterns (local IIS, remote store push, Exchange, issue-only, hold).

```powershell
.\07-Renew-And-Deploy.ps1 -WhatIfIssue                    # what WOULD issue, issues nothing
.\07-Renew-And-Deploy.ps1 -IssueOnly portal.example.com   # first prod issuance of ONE name
.\07-Renew-And-Deploy.ps1 -SkipIssue                      # renew + deploy only
.\07-Renew-And-Deploy.ps1 -ForceDeploy web01.example.com  # prove a hook without renewing
.\07-Renew-And-Deploy.ps1 -MaxIssuePerRun 2               # spread a big first run over nights
.\07-Renew-And-Deploy.ps1 -ExportDiagnostics              # one scrubbed support file
```

### Remote store pushes (`Push-CertToRemoteStore`)

An entry with `PushTarget` + `PushSecrets` gets its full-chain PFX copied over WinRM, imported into the target's `LocalMachine\My` **with the private key**, verified **by thumbprint** (never by name: a target can hold other, longer-lived certs for the same DNS name and a name match will "confirm" the wrong one), and the temp copy deleted in a `finally`. Nothing is bound, nothing restarted. `-RemoveSuperseded` is deliberately not passed: the target may still be bound to the previous cert.

```powershell
# As the SERVICE ACCOUNT, once:
Set-Secret -Name Exch01-Cred -Secret (Get-Credential)   # local admin on the target
Set-Secret -Name WinRM-Cred  -Secret (Get-Credential)   # or a shared fallback
Test-WSMan exch01.corp.example.net
.\07-Renew-And-Deploy.ps1 -ForceDeploy mail.example.com  # prove the push
```

### Exchange auto-bind (`Invoke-ExchangeBind`, opt-in)

The Exchange pattern in `CertHosts.example.ps1` pushes the cert, then - only when the entry has `ExchangeBind = $true` - binds it from the orchestrator:

1. **Revocation pre-check on the Exchange box** (`Invoke-Command`, `X509Chain` with online revocation). Fails closed: if the box cannot fetch the CA's CRL, Exchange would mark the cert `RevocationCheckFailure`, so nothing is bound.
2. **Probe** 443 and 25/STARTTLS; if both already serve the new thumbprint, stop (idempotent).
3. `Enable-ExchangeCertificate -Services IIS,SMTP -Force` by thumbprint over the `Microsoft.Exchange` remote endpoint (`http://<server>/PowerShell/`, Kerberos). The credential must be a **domain** account in Organization Management.
4. **Re-pin** `TlsCertificateName` (`<I>issuer<S>subject`, built from the new cert) on every connector in `ExchangeConnectors` (default `Default Frontend <SERVER>`), logging the old pin to `C:\Temp\rc-pin-history.txt` on the box, then restart `MSExchangeFrontEndTransport` once.
5. **Re-probe** (up to 6 x 10 s). A mismatch throws with the rollback command.

Leave `ExchangeBind = $false` (store push + `PARTIAL` notice every run) until the first bind and re-pin have been done and verified by hand with `09-Bind-ExchangeCert.ps1`. See the Exchange lessons below for why the pin exists at all.

## Self-repair, retries, and the circuit breaker

**Fixes itself** (logged as `REPAIRED:`): Mark-of-the-Web on the scripts, `POSHACME_PLUGINS` missing from a `-NoProfile` session, a missing or stale `EasyDNSFix.ps1` (hash-compared against the copy beside 07, refreshed *before* Posh-ACME is imported, because one bad plugin file breaks the whole module import), half-validated orders, one retry at a doubled `DnsSleep` for **transient** failures, one 120 s back-off for an easyDNS `420`, one retry for transient WinRM failures.

**Won't fix, by design:** missing/wrong credentials, a swapped token/key (a `420` on the first call is ambiguous between bad creds and throttling - run `02`, which verifies live), a name absent from the zone, anything needing a binding decision.

**CA rate limits** get their own handling from the **first** occurrence: the script parses Let's Encrypt's `retry after <timestamp>` and parks the host until then (24 h if no timestamp). Event ID 1006. Two limits read alike:

| Message | Limit | What helps |
| --- | --- | --- |
| `...for this exact set of identifiers` | duplicate certificate | only time; stop re-requesting a name you already hold |
| `...already issued for "example.com"` | per registered domain | `-MaxIssuePerRun 2` spreads issuance across nights |

**Circuit breaker:** after 3 consecutive failed runs for one host (`-BreakerThreshold`) the script stops calling the CA for it, still reports it FAILED so alerting never goes quiet, re-probes every 168 h (`-BreakerRetryAfterHours`), and `-ResetBreaker <fqdn>` (or `*`) clears it. Let's Encrypt caps failed validations per hostname; repeating a deterministic failure nightly can lock a name out.

## Logging - how you know it's working

| Sink | Location | Contents |
| --- | --- | --- |
| Text log | `C:\ProgramData\Posh-ACME-Renewal\renewal.log` | narrative + Posh-ACME verbose stream; rotates at 5 MB, keeps 5; every run ends in exactly one `RESULT: OK` / `RESULT: FAILED` line |
| Status file | `C:\ProgramData\Posh-ACME-Renewal\last-run.json` | result, duration, who ran it, issued/renewed/deployed/notices/failures, per-host NotAfter + DaysLeft, breaker state |
| Event log | Application, source `ACME-Renewal` | 1000 OK, 1001 FAILED, 1002 issued, 1003 deployed, 1004 expiring inside `-ExpiryWarnDays` (21), 1005 breaker opened, 1006 CA rate-limit hold |

**Monitor on two things.** `RESULT: FAILED` / event 1001 catches a run that went wrong. It does not catch a task that never ran: also alert when `last-run.json`'s `StartedUtc` is older than ~36 h. An independent external expiry probe on each public endpoint is the only check that catches "issued but not actually serving".

```powershell
$s = Get-Content C:\ProgramData\Posh-ACME-Renewal\last-run.json | ConvertFrom-Json
$s | Select-Object Result, StartedUtc, DurationSec, @{n='Failures';e={$_.Failures -join '; '}}
$s.Certs | Format-Table Domain, Mode, DaysLeft, NotAfter -AutoSize
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='ACME-Renewal'} -MaxEvents 20
```

## The rules that break everything if ignored

1. **Profile-specific state.** The secret vault AND all Posh-ACME state live in the service account's profile (`$env:LOCALAPPDATA\Posh-ACME`). The account that runs `02` must be the account the scheduled task uses. Any other account sees nothing, and the task "succeeds" nightly while renewing nothing.
2. **pwsh 7 only** for `02`, `03`, `07`, `08` (they enforce it). Windows PowerShell 5.1 fails TLS against these APIs. Exception: `06` deliberately relaunches itself *into* 5.1 because `WebAdministration` under pwsh 7 returns deserialized objects with no methods.
3. **`-Plugin EasyDNSFix`, never the built-in `EasyDNS`.** See below.
4. **One issuance at a time.** easyDNS allows 1 request/second and 500/day (reset 12 AM EST). The plugin paces itself; do not run parallel attempts.
5. **Keep every `.ps1` pure ASCII.** The files are BOM-less UTF-8, which Windows PowerShell 5.1 reads as ANSI: a single em-dash or curly quote becomes `Unexpected token`, usually far from the real line. Check before committing:

   ```powershell
   Get-ChildItem *.ps1 | Where-Object { [IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 127 } } | Select-Object Name
   ```

6. **Never delete a superseded cert's private key.** Posh-ACME reuses one key across renewals, so the old and live certs share a key container. `-DeleteKey` on the old cert kills the live one with "Keyset does not exist", and the failure is **delayed** until the next `iisreset`/reboot. `05 -RemoveSuperseded` removes cert *entries* only. After any key-related repair: `iisreset`, then verify externally.

## easyDNS API - learned the hard way

- **Auth** = HTTP Basic `token:key` against `https://rest.easydns.net`. Sandbox = `https://sandbox.rest.easydns.net`, separate creds, separate counters; sandbox writes never reach public DNS.
- **Labels, not prefixes.** Enter the values exactly as labeled Token / Key on the portal's Production Details page. The string prefixes come from the *name* typed at creation and mean nothing. A swapped pair produced a full day of misleading errors; `02` now verifies live and auto-corrects the order.
- **The Key shows only at creation.** Not captured = regenerate. Regenerating **instantly invalidates the previous pair**.
- **Errors hide behind HTTP 200.** Wrong creds, stale creds, rate limiting and unknown zones can all return `200 OK` with `{"error":{"code":420,"message":"Enhance Your Calm..."}}`. A 420 on the *first* call of a session = bad credentials until proven otherwise; 420s after a burst = rate limit.
- **Endpoints used:** `GET /zones/records/all/<zone>?format=json`, `PUT /zones/records/add/<zone>/txt?format=json` (JSON body: domain, host, ttl, prio, type, rdata; returns `status: 201`), `DELETE /zones/records/<zone>/<id>?format=json`.

### Why `EasyDNSFix` exists

Posh-ACME's built-in `EasyDNS` plugin discovers the zone by querying candidate names "until successful". easyDNS answers errors with HTTP 200, so the plugin accepts its *first* candidate (`_acme-challenge.<host>.<zone>`, never a real zone), writes the TXT there, and validation fails with NXDOMAIN. `EasyDNSFix` treats an `.error` body as failure regardless of HTTP status, requires a real record list before accepting a zone, sleeps 1.5 s before every call, and throws a clear message on 420. Usage is identical: `-Plugin EasyDNSFix -PluginArgs @{ EDToken = ...; EDKey = ... }`.

`01` installs it to `C:\ProgramData\Posh-ACME-Plugins` (machine env var `POSHACME_PLUGINS`) and as a fallback copy inside the module's own `Plugins` folder. Verify in a **new** pwsh window: `Get-PAPlugin | ? Name -eq EasyDNSFix`. `07` re-syncs both copies from the file beside it every run.

## Deploying to Windows / IIS

IIS binds by **thumbprint**, which changes at every renewal even though the key is reused, so the per-renewal IIS deploy is always the pair **05 import, then 06 rebind** - which is what the local-IIS pattern in `CertHosts.example.ps1` automates.

```powershell
.\05-Import-CertToStore.ps1 -MainDomain web01.example.com -InstallChain            # elevated, as the service acct
.\05-Import-CertToStore.ps1 -PfxFile D:\certs\fullchain.pfx -PfxPass poshacme       # from a copied PFX
.\06-Bind-IISCert.ps1 -Domain web01.example.com                                     # Default Web Site *:443
.\06-Bind-IISCert.ps1 -Domain portal.example.com -SiteName 'Portal' -HostHeader 'portal.example.com'   # SNI
.\06-Bind-IISCert.ps1 -Thumbprint <old>                                             # rollback (06 prints it)
```

`06 -Domain` picks the newest-**issued** cert (`NotBefore`), not the latest-expiring, so a leftover 1-year commercial cert never beats a fresh 90-day LE cert. Both scripts refuse staging-issued certs without confirmation and support `-WhatIf`.

## When something breaks

```powershell
.\08-AcmeDoctor.ps1 -VerifyZone example.com            # read-only report
.\08-AcmeDoctor.ps1 -VerifyZone example.com -Repair    # apply fixes (elevated)
.\07-Renew-And-Deploy.ps1 -ExportDiagnostics           # one scrubbed file to send for help
```

The doctor checks plugin registration, vault creds (live, with swap detection), orders on the broken built-in plugin, stuck orders, keyless store certs, http.sys serving the newest cert (`-LocalDomains`), and the task wiring. The diagnostics export collects config, live order state, cert store, task, breaker state and the log tail, with token/key/password values replaced by `[REDACTED]`.

| Symptom | Cause | Fix |
| --- | --- | --- |
| `No such host is known` (Set-PAServer) | server can't resolve letsencrypt.org | check DNS; compare `Resolve-DnsName x -Server 8.8.8.8` |
| `was not valid JSON` (Set-PAServer) | proxy / firewall intercepting outbound 443 | egress exception for both `*.api.letsencrypt.org` hosts |
| TLS / `underlying connection was closed` | Windows PowerShell 5.1 | use pwsh 7 |
| 420 on the first call | wrong / stale / swapped easyDNS creds | re-run `02` |
| 420 after several calls | rate limit | wait; daily reset 12 AM EST; ONE retry |
| Plugin "not found or was invalid" | stale session env | `$env:POSHACME_PLUGINS='C:\ProgramData\Posh-ACME-Plugins'; Import-Module Posh-ACME -Force` |
| Validation NXDOMAIN | built-in `EasyDNS` plugin | `-Plugin EasyDNSFix` |
| Task runs but renews nothing | task user is not the account that ran `02` | re-register with the right `-TaskUser` |
| `Keyset does not exist` after iisreset | an old cert was deleted **with** its shared key | `08 -Repair`, rebind, `iisreset`, verify externally |
| Cert renewed but site serves the old one | renewal without the 05+06 deploy | ensure the task runs `07`; test with `-ForceDeploy` |
| Added a SAN to `Names`, cert never changes | old runner skipped valid orders; `Submit-Renewal` renews the old name set | current `07` reissues on SAN mismatch; preview with `-WhatIfIssue` |
| Exchange event 12014, no STARTTLS on 25 | stale `TlsCertificateName` pin (CA rotated its intermediate) | re-pin from the live cert's real issuer; `ExchangeBind` does this every renewal |
| Exchange cert `RevocationCheckFailure` | box cannot fetch the CA CRL over plain HTTP (captive portal / proxy) | allow HTTP egress to the CRL host (e.g. `*.lencr.org`) from the server |

## Lessons learned

General:

- **SAN edits need a reissue.** `Submit-Renewal` renews the name set the order was created with, forever. `07` now compares a valid cert's SANs against `Names` and reissues on mismatch. Preview with `-WhatIfIssue` - but note `-WhatIfIssue` still runs `Submit-Renewal`.
- **Verify pushes by thumbprint, never by name.** A target can hold an older, longer-lived cert for the same name.
- **One issuer per name.** Appliances with native ACME (e.g. FortiOS) and boxes running acme.sh locally should self-manage; never also issue the same name from the orchestrator (LE duplicate-certificate limit: 5 per week). Keep them as commented-out `CertHosts` entries and monitor their expiry separately - native ACME usually uses HTTP-01, so port 80 must reach the box.

Exchange (details in `docs/RUNBOOK.md`, Phase 4):

- The Default Frontend receive connector's `Fqdn` **cannot** be changed to the public name while `AuthMechanism` includes `ExchangeServer` (`InvalidFqdnUnderExchangeServerAuthException`), so name-based cert selection is impossible and port 25 needs a `TlsCertificateName` pin. Rebuild the pin from the new cert's real issuer on every renewal; a stale issuer string after a CA intermediate rotation means event 12014 and no STARTTLS.
- **Clearing** a pin without changing `Fqdn` makes Exchange pick the self-signed server cert - the internet sees self-signed.
- A custom `:25` receive connector with internal `RemoteIPRanges` (e.g. an internal relay connector) wins for internal clients, including your own probe. Pin it too, or verification fails falsely and internal relays get the self-signed cert.
- Run the revocation check **on the Exchange box**. LE is CRL-only (no OCSP); a captive portal intercepting plain-HTTP egress breaks it, and `certutil` showing AIA "Verified" proves nothing about egress.
- Exchange remote PowerShell (including locally launched EMS) drops `Services` / `CertificateDomains`; verify on the wire or via `Cert:\`. The snap-in inside `Enter-PSSession` fails with `ADInvalidCredentialException` (double hop); use the `Microsoft.Exchange` remote endpoint.
- Benign after an LE swap: events 12017/12018 ("will expire soon" - 90-day certs trip it). Dangerous: 12014.
- Never hand-type an issuer pin and forget it; never rebind IIS 444 (Exchange Back End) or 8172.
- Hybrid: `Get-HybridConfiguration` `TlsCertificateName` can hold a stale pin that the HCW pushes back onto the connectors. Update it after any cert change.
- Queue checks: `Get-Queue`, `Get-Message -Filter "Status -eq 'Retry'"`. Queue Viewer may crash with "Failed to enable constraints"; use the cmdlets.

## Credits and license

Written by **Andrew Cohen**, [Signal Point Technologies](https://signalpointtech.com). Built for a real client fleet, then sanitized and generalized for reuse.

MIT. No warranty; it touches production certificates, read it before you run it.
