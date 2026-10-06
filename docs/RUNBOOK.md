# SSL Certificate Auto-Rotation Runbook (template)

**Goal:** replace manual commercial-CA renewals with **unattended ACME (Let's Encrypt) rotation** for every public-facing host, on a self-renewing cycle that stays well inside any "renew every N months" requirement.

**Companion:** [`../README.md`](../README.md) (the toolchain and its lessons learned) and `scripts/` (the as-built implementation).

> **How to use this document.** It is a phased plan with a per-platform procedure, verification and rollback for each phase. Replace every `<...>` placeholder and every `example.com` / `example.net` name with your own before executing anything. Phases 0, 1 and the IIS phase are fully scripted; the others are procedures the scripts support (issue + store push) but do not finish (the binding step).

---

## Why automate

Public-CA maximum certificate lifetimes are collapsing: the CA/Browser Forum cap is 200 days as of March 2026 and is scheduled to fall to about 47 days by 2029. A manual "every few months" process is already near the limit and will soon be unworkable by hand. ACME automation makes lifetime irrelevant: certs renew themselves inside their window and any calendar requirement is satisfied as a side effect.

---

## Architecture

- **CA:** Let's Encrypt (DV). **Challenge:** **DNS-01** (no inbound ports; validates internal-only names; uniform for every host). **Scope:** one **per-host SAN cert** per FQDN (smallest blast radius if a key leaks).
- **Central orchestrator:** one Windows Server running **Posh-ACME**. It is the single issuer, holds the DNS API credentials in one DPAPI-bound vault, runs the daily task, and writes one log + status file. If it is also an IIS host, that host's deploy is purely local.
- **Service account:** the vault and all Posh-ACME state live in **one user profile**. The account that runs `02-Setup-Vault-Account.ps1` is the account the scheduled task must run as. Any other account sees an empty state.
- **Deploy** is per platform (a freshly issued cert is pushed to its target by a hook in `CertHosts.ps1`): local IIS via `05` + `06`; remote Windows (IIS, Exchange) via a WinRM **store push** with the binding done in a window; network appliances via their REST API; Linux hosts self-manage with `acme.sh`; anything without an API stays "issue here, upload by hand".
- **Alternatives on file:** *Certify The Web* (paid GUI with vendor support and built-in deploy tasks) if a supported product is preferred over scripts; per-host **win-acme** agents as a lower-setup fallback (trade-off: DNS creds spread to every host, no single pane).

> **Why not the firewall's native ACME?** Most appliance ACME implementations use **HTTP-01** and need **port 80 open on the WAN interface**. Central DNS-01 plus an API push keeps the edge closed and the method uniform.

---

## Guiding principles

1. **Staging before production.** Prove issue -> deploy -> reload against `LE_STAGE` first. Switch to `LE_PROD` only once a full dry run passes; production has rate limits.
2. **One host, one window, one validation.** Cut over a single host per change; verify it serves the new cert end to end before the next.
3. **Keep the old cert until proven.** Import the new cert alongside the current one, switch the binding, verify, **then** remove the old. Every step lists a rollback.
4. **Secrets to the vault.** DNS API tokens, appliance API keys, exported PFX files: secret store only, never email or shared drives.
5. **Monitoring is never dark.** Alert on `RESULT: FAILED`, on a run that never happened, and on an external expiry probe.
6. **Never delete an old cert's private key.** Posh-ACME reuses one key across renewals; `-DeleteKey` on a superseded cert destroys the live cert's key, and the failure is delayed until the next restart.

---

## Suggested order

| Phase | Scope | Why this order |
| --- | --- | --- |
| **0** | Prerequisites: DNS API per zone, LE account, reachability, vault | Nothing issues without DNS-01 working. **Gating.** |
| **1** | Orchestrator build (Posh-ACME + DNS-01 + scheduler), staging-proven | The single issuer everything depends on. |
| **2** | **Pilot: the simplest IIS host** (ideally the orchestrator itself) | Local deploy, no remoting to prove at the same time as the ACME path. |
| **3** | Other IIS hosts (store push, then SNI binding) | Same pattern, add WinRM. |
| **4** | Exchange | Change-sensitive (mail flow); do after the pattern is proven. |
| **5** | Firewalls / VPN appliances (REST API) | Highest value, highest blast radius; go last among the automatable hosts. |
| **6** | Linux hosts (`acme.sh`, self-managing) | Independent of the Windows path. |
| **7** | Appliances with no API | Least automatable; may stay semi-manual. |
| **8** | Monitoring, alerting, handoff | Close the loop. |

> Do **not** sink automation into a box scheduled for retirement. Bridge it with a short manual cert and bake ACME into its replacement instead.

---

## Phase 0 - Prerequisites (no changes; gating)

**0.1 - Identify the authoritative DNS provider for every zone in scope.** They can differ per zone.

```bash
dig +short NS example.com
dig +short NS example.net
```

**0.2 - Obtain an API credential for each provider.** For easyDNS: a REST **Token + Key** pair from the portal's *Production Details* page. For any other provider, confirm Posh-ACME has a plugin; if none, use the CNAME-delegation fallback in 0.5.

> **easyDNS credential rules (these cost a day of misdiagnosis):** auth is HTTP Basic `token:key`; enter the values exactly as **labeled** Token / Key (the string prefixes come from the name typed at creation and mean nothing); the Key shows only at creation and **regenerating instantly invalidates the previous pair**; bad creds, stale creds and rate limiting all return HTTP 200 with a `420 "Enhance Your Calm"` body; hard limits are **1 request/second and 500/day**. One issuance at a time.

**0.3 - Confirm reachability, orchestrator -> each target:** appliances on their HTTPS admin/API port; Windows hosts on **WinRM 5985/5986**; Linux hosts on SSH.

**0.4 - Confirm outbound 443 to Let's Encrypt is not intercepted.** `Set-PAServer` failing with *"was not valid JSON"* means a proxy/web filter is breaking the API; *"No such host is known"* means DNS. Allow `acme-v02.api.letsencrypt.org` and `acme-staging-v02.api.letsencrypt.org`.

**0.5 - DNS-01 fallback (only if a zone's provider has no usable API):** delegate just the challenge record.

```text
# In the zone that CANNOT be automated, add a static CNAME once:
_acme-challenge.<host>.<zone>.  CNAME  <host>.<zone>.<automatable-zone>.
# ACME then writes the TXT in the automatable zone; the static CNAME never changes.
```

**0.6 - Optional network smoke test:** `00-Test-EasyDNS-Sandbox.ps1 -Token <sandbox-token> -Key <sandbox-key> -Zone <zone>` proves a machine's path to the easyDNS API with **sandbox** credentials (separate counters; sandbox writes never reach public DNS).

**Verify:** `dig NS` returns the expected nameservers per zone; a test TXT record can be created and deleted via the API; each target answers on its management port from the orchestrator.
**Rollback:** none (read-only). Do not proceed until DNS-01 is proven for every zone in scope.

**Decisions to capture leaving Phase 0:** LE contact address; DNS provider per zone; which box is the orchestrator; the ACME service account.

---

## Phase 1 - Orchestrator build (staging only)

Fully scripted. Run from `scripts\`, in order. Each step names the account and the shell it needs; getting either wrong is the most common way this build fails silently.

**1.1 - `01-Install-Prereqs.ps1`** - any local admin, **elevated**, PS 5.1 or 7. Installs PowerShell 7, the modules, and the `EasyDNSFix` plugin. Verify **in a new pwsh window**: `Get-PAPlugin | ? Name -eq EasyDNSFix`.

**1.2 - `02-Setup-Vault-Account.ps1 -VerifyZone <zone> -ContactEmail <addr>`** - **as the service account**, pwsh 7. Registers the vault in unattended mode, stores and **live-verifies** the DNS credentials (auto-correcting a swapped pair), creates the LE **staging** account.

**1.3 - `03-Test-StagingCert.ps1 -Hosts <one name per zone>`** - same account, pwsh 7. **This is the gate:** every zone must print `PASS` before any production issuance. Staging certs are untrusted by design; never deploy one.

**1.4 - Production account** - same account, pwsh 7:

```powershell
Set-PAServer LE_PROD
New-PAAccount -AcceptTOS -Contact 'mailto:<your-contact-email>'
```

Posh-ACME keeps both accounts; `Set-PAServer` toggles between them for future dry runs.

**1.5 - Inventory** - copy `CertHosts.example.ps1` to `CertHosts.ps1` and describe every host (see the five patterns in the example). Then:

```powershell
.\07-Renew-And-Deploy.ps1 -WhatIfIssue     # lists what would issue; issues nothing
```

**1.6 - `04-Register-RenewalTask.ps1 -TaskUser '<DOMAIN\svc-acme>'`** - local admin, **elevated**, pwsh 7. Registers the daily `ACME-Renewal` task (RunLevel Highest) that runs `07-Renew-And-Deploy.ps1`. **`-TaskUser` must be the exact account that ran `02`.** Smoke test:

```powershell
Start-ScheduledTask -TaskName 'ACME-Renewal'
Get-Content C:\ProgramData\Posh-ACME-Renewal\renewal.log -Tail 30
```

Expected before any production cert: a header line and `RESULT: OK` with nothing to renew.

**Verify:** `Get-PACertificate <fqdn>` shows a cert with the STAGING issuer; every zone passed `03`.
**Rollback:** `Remove-PACertificate <fqdn>`; nothing has been deployed to any host.

### Phase 1 troubleshooting

See the table at the end of [`../README.md`](../README.md). When anything misbehaves, run `08-AcmeDoctor.ps1 -VerifyZone <zone>` first, then with `-Repair`.

---

## Phase 2 - Pilot: local IIS host

**Purpose:** the simplest case. If the orchestrator is itself an IIS host, its deploy is a local script call and nothing else has to be proven at the same time as the ACME path.

**2.1 - Issue the production cert** (service account, pwsh 7, one at a time):

```powershell
.\07-Renew-And-Deploy.ps1 -IssueOnly web01.example.com
```

With a local-IIS entry in `CertHosts.ps1` (pattern 1 in the example) the deploy hook runs as part of issuance: `05` imports into `LocalMachine\My` with the chain and removes superseded cert **entries**, `06` rebinds the site to the new thumbprint and prints the previous thumbprint (the rollback handle).

**2.2 - Prove the hook without waiting for a renewal:**

```powershell
.\07-Renew-And-Deploy.ps1 -ForceDeploy web01.example.com
```

> **Why the rebind is needed every renewal:** IIS binds by thumbprint, which is a hash of the whole certificate and changes at every renewal even though Posh-ACME reuses the key. The per-renewal IIS deploy is always the pair **05 import -> 06 rebind**.
>
> **NEVER delete a superseded cert's private key.** The superseded and the live certificate share one key container. Deleting the old cert **with** its key kills the live cert with "Keyset does not exist", and IIS keeps serving from memory until the next `iisreset` or reboot, so the failure surfaces days later. `05 -RemoveSuperseded` removes entries only. After any key-related repair: `iisreset`, then re-check externally.

**Verify:** `Get-ChildItem IIS:\SslBindings` shows the new thumbprint; `openssl s_client -connect <host>:443 -servername <fqdn>` shows the Let's Encrypt issuer and new dates; the site loads without warnings.
**Rollback:** `.\06-Bind-IISCert.ps1 -Thumbprint <old thumbprint>`.

---

## Phase 3 - Other IIS hosts (remote)

**Purpose:** same method over WinRM. Stage 1 is automated; stage 2 is a short manual step until proven, then automated.

**3.1 - Store push (automated).** Add the host as pattern 2 in `CertHosts.ps1` (`PushTarget` + `PushSecrets`). As the service account, store a credential with local-admin rights on the target, confirm WinRM, and prove the push:

```powershell
Set-Secret -Name Web02-Cred -Secret (Get-Credential)
Test-WSMan web02.example.com
.\07-Renew-And-Deploy.ps1 -ForceDeploy portal.example.com
```

The cert and its private key now sit in the target's `LocalMachine\My`. Nothing is bound.

**3.2 - Bind (manual the first time).** On the target, elevated:

```powershell
.\06-Bind-IISCert.ps1 -Domain portal.example.com -SiteName '<site>' -HostHeader 'portal.example.com'   # SNI-bound site
```

**Bind by thumbprint** if the store holds other certs for the same name; the push logs them.

**3.3 - Promote.** Once the binding is proven, extend the entry's `Deploy` hook to also run `06` remotely (or move the whole deploy to a local scheduled script on the target) and drop the `DeployNote`.

**Verify:** `openssl s_client` shows the LE issuer; the site loads; if the site uses AD/SSO auth, **complete a real login** (the auth flow is the sensitive part, not just TLS).
**Rollback:** re-bind the previous thumbprint; review SNI / host headers before retrying.

---

## Phase 4 - Exchange (IIS + SMTP)

**Purpose:** rotate the Exchange cert and re-bind services without disrupting mail flow. **Change-sensitive; schedule a window.**

**4.1 - SAN set.** Check the history of certs the host has used (`Get-ExchangeCertificate | fl Subject, CertificateDomains`) and keep only the names something actually uses. Each extra SAN is another DNS-01 challenge that can fail unattended. Do not add `autodiscover.*` unless DNS actually points it at this host.

**4.2 - Store push (automated).** Pattern 3 in `CertHosts.ps1` with `ExchangeBind = $false`. Prove with `-ForceDeploy mail.example.com`. Mail flow is untouched: nothing is enabled, and every run logs a `PARTIAL` notice.

**4.3 - Pre-checks (on the Exchange box).**

- Revocation: `certutil -urlfetch -verify <exported .cer>` must fetch the CRL over the network. LE is CRL-only (no OCSP). A firewall captive portal intercepting plain-HTTP egress returns a login page instead of the CRL and Exchange marks the cert `RevocationCheckFailure`. AIA lines saying "Verified" come from the local cache and prove nothing about egress.
- Connectors: `Get-ReceiveConnector -Server <SERVER> | ? Bindings -match ':25' | fl Identity,Fqdn,AuthMechanism,RemoteIPRanges,TlsCertificateName`. Every `:25` connector that can answer a TLS client must be pinned in 4.4 (a custom relay connector with internal `RemoteIPRanges` wins over Default Frontend for internal senders).
- Hybrid: `Get-HybridConfiguration | fl TlsCertificateName` - note it; it must be updated in 4.4 too.

**4.4 - First bind + re-pin (manual, in the window).** On the Exchange box, Windows PowerShell 5.1:

```powershell
.\09-Bind-ExchangeCert.ps1 -Domain mail.example.com -RequiredNames mail.example.com,smtp.example.com -WhatIf
.\09-Bind-ExchangeCert.ps1 -Domain mail.example.com -RequiredNames mail.example.com,smtp.example.com
# 09 prints the previously-bound thumbprints - keep them for rollback.

$c   = Get-Item Cert:\LocalMachine\My\<tp>
$pin = "<I>$($c.Issuer)<S>$($c.Subject)"      # built from the cert, never typed
foreach ($rc in 'Default Frontend <SERVER>', '<internal relay connector>') {
    (Get-ReceiveConnector "<SERVER>\$rc").TlsCertificateName | Add-Content C:\Temp\rc-pin-history.txt
    Set-ReceiveConnector "<SERVER>\$rc" -TlsCertificateName $pin
}
Restart-Service MSExchangeFrontEndTransport
Set-HybridConfiguration -TlsCertificateName $pin   # hybrid only
```

Why a pin and not name-based selection: `Set-ReceiveConnector "Default Frontend <SERVER>" -Fqdn mail.example.com` is refused (`InvalidFqdnUnderExchangeServerAuthException`) because `AuthMechanism` includes `ExchangeServer`. With the `Fqdn` stuck on the server name, **clearing** the pin makes Exchange select the self-signed server cert for port 25.

**4.5 - Automate.** Once 4.4 is verified, set `ExchangeBind = $true` (and `ExchangeConnectors` if there is more than Default Frontend) in the `CertHosts.ps1` entry. From then on every renewal runs `Invoke-ExchangeBind` from the orchestrator: revocation pre-check on the box (fail closed), bind, re-pin from the new cert's real issuer (so CA intermediate rotation cannot strand the pin), restart FrontEndTransport, verify 443 + 25/STARTTLS by thumbprint.

**Verify:** OWA/ECP load over HTTPS with the new cert; send and receive a test message (internal and external); `openssl s_client -connect <host>:443` and `openssl s_client -starttls smtp -connect <host>:25` both show the new cert; no event 12014 in the Application log; `Get-Queue` shows nothing stuck in Retry.
**Rollback:** `Enable-ExchangeCertificate -Thumbprint <old-tp> -Services IIS,SMTP -Force` (or `09 -Thumbprint <old-tp>`), then restore each connector's pin from `C:\Temp\rc-pin-history.txt` and restart `MSExchangeFrontEndTransport`.

### Phase 4 lessons and troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Event 12014 (FrontEndTransport), no STARTTLS on 25 | `TlsCertificateName` pin names an issuer that no longer matches (CA rotated its intermediate - happened with a commercial CA) | rebuild the pin from the live cert; `ExchangeBind` does it every renewal |
| Internet sees the self-signed server cert on 25 | pin cleared while `Fqdn` is still the server name | re-pin; do not clear |
| Internal probe / relays get self-signed, external is fine | a custom `:25` connector with internal `RemoteIPRanges` is unpinned | add it to `ExchangeConnectors` and pin it |
| `Status: RevocationCheckFailure` | server cannot fetch the CRL over plain HTTP | allow HTTP egress to the CRL host; check from the server itself |
| `Services` / `CertificateDomains` missing from output | Exchange remote PowerShell (incl. local EMS) drops them | verify on the wire, or `Get-Item Cert:\LocalMachine\My\<tp>` |
| `ADInvalidCredentialException` loading the snap-in | snap-in inside `Enter-PSSession` = Kerberos double hop | use `New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri http://<server>/PowerShell/`, or a local logon |
| Events 12017 / 12018 "will expire soon" | 90-day certs trip the warning threshold | benign |
| Queue Viewer crashes "Failed to enable constraints" | MMC bug | `Get-Queue`; `Get-Message -Filter "Status -eq 'Retry'"` |
| Pin re-appears stale after the HCW | `Get-HybridConfiguration` `TlsCertificateName` still old | `Set-HybridConfiguration -TlsCertificateName <pin>` after any cert change |

Never rebind IIS port 444 (Exchange Back End, keeps the self-signed cert) or 8172 (WMSvc); `Enable-ExchangeCertificate -Services IIS` only touches Default Web Site.

---

## Phase 5 - Firewall / VPN appliance (REST API)

**Purpose:** prove issue -> API import -> bind -> reload on the highest-value target. On an HA pair, operate on the primary only; config syncs to the standby.

> **Check for native ACME first.** Recent firmware on many appliances (FortiOS included) has a built-in ACME client. If it does, let the box issue and renew its own cert and keep only a commented-out `CertHosts.ps1` entry with the reason - never also issue the name from the orchestrator (duplicate-certificate limit, 5 per week). Native ACME usually uses HTTP-01, so port 80 must reach the box; monitor its expiry externally since the orchestrator no longer sees it. The REST-push procedure below is for appliances without native ACME.

**5.1 - Issue** (pattern 4 in `CertHosts.ps1` until the hook exists): `.\07-Renew-And-Deploy.ps1 -IssueOnly vpn1.example.net`. Files land under `$env:LOCALAPPDATA\Posh-ACME\<server>\<account>\<fqdn>\` (`Get-PACertificate <fqdn> | fl *File*`).

**5.2 - Push via the appliance API** (representative FortiOS calls; use an API admin scoped to certificate import):

```powershell
$fg = 'https://<appliance>:<admin-port>'; $H = @{ Authorization = "Bearer <api-key>" }
# Import under a date-stamped name; do NOT overwrite the in-use one yet
Invoke-RestMethod -Method POST -Uri "$fg/api/v2/monitor/vpn-certificate/local/import" -Headers $H `
  -Body (@{ type='regular'; scope='global'; certname='LE-vpn1-<yyyymm>';
            key_file_content=<b64 key>; file_content=<b64 fullchain> } | ConvertTo-Json)
# Switch the admin GUI + SSL-VPN to the new cert
Invoke-RestMethod -Method PUT -Uri "$fg/api/v2/cmdb/system/global" -Headers $H `
  -Body (@{ 'admin-server-cert'='LE-vpn1-<yyyymm>' } | ConvertTo-Json)
Invoke-RestMethod -Method PUT -Uri "$fg/api/v2/cmdb/vpn.ssl/settings" -Headers $H `
  -Body (@{ servercert='LE-vpn1-<yyyymm>' } | ConvertTo-Json)
```

Wrap those calls in the entry's `Deploy` scriptblock once proven; store the API key in the vault, never in the script.

**Verify:** `openssl s_client -connect <appliance>:<port> -servername vpn1.example.net` shows the LE issuer; on an HA pair confirm the standby is in sync; a VPN client still connects.
**Rollback:** re-point both bindings to the prior cert name; delete the LE entry if needed.

---

## Phase 6 - Linux host (self-managing with acme.sh)

**Purpose:** local renewal on the box is cleaner than pushing to Linux from Windows. **Do not also list the name in `CertHosts.ps1`:** two issuers for one name burn the Let's Encrypt duplicate-certificate limit (5 per week).

```bash
curl https://get.acme.sh | sh -s email=<your-contact-email>
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
export EASYDNS_Token='<token>'; export EASYDNS_Key='<key>'

~/.acme.sh/acme.sh --issue --dns dns_easydns -d tunnel.example.net --staging   # dry run first
~/.acme.sh/acme.sh --issue --dns dns_easydns -d tunnel.example.net

~/.acme.sh/acme.sh --install-cert -d tunnel.example.net \
  --key-file       /etc/<service>/private/site.key \
  --fullchain-file /etc/<service>/certs/site.crt \
  --reloadcmd      "sudo systemctl reload <service>"
```

This host shares the DNS account's daily API budget with the orchestrator. acme.sh's `dns_easydns` hook is a different implementation from Posh-ACME's built-in plugin and is not known to have its zone-detection bug, so `EasyDNSFix` applies to the Windows path only - but still run the staging issue first. Use RSA-2048 (`--keylength 2048`) if older clients must connect. Schedule the first cutover in a quiet window if the reload drops sessions.

**Verify:** the service reports healthy; `openssl s_client` shows the LE issuer; `~/.acme.sh/acme.sh --list` shows the cron-driven renewal.
**Rollback:** restore the previous `site.crt`/`site.key` from backup and reload.

> If the "Linux host" turns out to be a **vendor-managed appliance** whose certificate the vendor really issues, exclude it entirely and leave a commented-out entry with the reason. Check the product docs before assuming: Microsoft Tunnel Gateway, for example, uses an **admin-supplied** PEM loaded with `mst-cli import_cert`, so acme.sh on the box is the right pattern for it. **Full tested procedure and gotchas: [`MS-TUNNEL-GATEWAY.md`](MS-TUNNEL-GATEWAY.md)**. In short: a leftover `site.pfx` takes priority over the PEM pair, `import_cert` exits 0 on failure, and the reload hook must be `printf '\n' | mst-cli import_cert && mst-cli server restart`.

---

## Phase 7 - Appliance with no API

**Purpose:** decide automated vs semi-manual.

1. **API spike:** confirm whether the appliance exposes a REST API for certificate upload and apply. If yes, script it as a `Deploy` hook (upload PKCS#12, apply, restart the service).
2. **If no API:** keep the entry as pattern 4/5 in `CertHosts.ps1` (issued and renewed centrally), and have the run's event-log `1002 issued` entry alert an operator to upload the PFX via the admin UI. Budget 15-30 minutes per cycle.

**Verify:** `openssl s_client` on the service and admin ports; a client checks in successfully.
**Rollback:** re-upload the previous cert via the admin UI and restart the service.

---

## Phase 8 - Monitoring, alerting and handoff

The daily runner is `07-Renew-And-Deploy.ps1`; what it does, its inventory modes, its logging sinks and the circuit breaker are documented in [`../README.md`](../README.md).

- **Alert on `RESULT: FAILED`** in `renewal.log` (or Application event `1001`); the task's non-zero exit code is the secondary signal. Route to a webhook / email / syslog.
- **Alert on absence:** `last-run.json`'s `StartedUtc` older than ~36 h means the task never ran, a state no `RESULT: FAILED` line will ever report.
- **External expiry probe:** an independent daily check of each public endpoint's `NotAfter`, alerting at < 21 days. It is the only check that catches "issued but not actually serving". Event `1004` is the internal backstop.
- **Health check:** `08-AcmeDoctor.ps1 -VerifyZone <zone>` is the first thing to run on any alert.
- **Handoff:** record the service account, the vault, the deploy hook per host (`CertHosts.ps1`), the log path and this runbook in the ops wiki; name the owner of any semi-manual step.

---

## Effort (one-time setup)

| Phase | Work | Effort |
| --- | --- | --- |
| 0 | Prereqs | 0.5 d |
| 1 | Orchestrator (scripted) | 1-2 h on a repeat build; 1 d first time |
| 2 | IIS pilot | 0.25 d |
| 3 | Each further IIS host | 0.25 d |
| 4 | Exchange (windowed) | 0.5-1 d |
| 5 | Each appliance with an API | 0.5 d |
| 6 | Each Linux host | 0.5 d |
| 7 | Appliance without an API | 0.5-1 d |
| 8 | Monitoring / handoff | 0.5-1 d |

**Ongoing per rotation:** ~0 for automated hosts; 15-30 min for any semi-manual appliance.

---

## Risk and rollback summary

| Risk | Mitigation | Rollback |
| --- | --- | --- |
| A zone's DNS provider has no usable API | CNAME-delegate `_acme-challenge.<host>` to an automatable zone (one-time) | n/a (discovery) |
| New cert breaks admin/VPN access on an appliance | Import alongside, switch, verify in a held session before removing the old | Re-point bindings to the prior cert |
| Exchange swap disrupts mail flow | Windowed change; revocation pre-check on the box; pin every `:25` connector; test send/receive and OWA before closing | `Enable-ExchangeCertificate` previous thumbprint; restore pins from `C:\Temp\rc-pin-history.txt` |
| Stale Exchange `TlsCertificateName` pin after CA intermediate rotation (12014) | Pin rebuilt from the live cert on every bind (`ExchangeBind`); hybrid config updated too | Re-pin from the current cert |
| SAN edit silently never applied | `07` reissues when cert SANs differ from `Names` | `-WhatIfIssue`, then let the run reissue |
| Auth login breaks after an IIS cert swap | Validate a real login per host | Re-bind previous thumbprint; review SNI/host headers |
| Appliance has no automation path | API spike; fall back to auto-issue + alert + manual upload | Re-upload previous cert |
| Silent deploy failure leaves an expiring cert | External expiry probe; `07` fails a renewed domain with no deploy hook | Manual re-issue/deploy; fix the hook |
| Automating a box that is about to be retired | Bridge with a short manual cert; bake ACME into the replacement | n/a |
| **Deleting a superseded cert's key kills the live cert** | `05 -RemoveSuperseded` removes entries only; never `-DeleteKey`; failure is delayed until restart | Re-import (`05`), rebind (`06`), `iisreset`, verify; `08 -Repair` detects keyless certs |
| Built-in `EasyDNS` plugin writes challenges into a nonexistent zone | `EasyDNSFix` in every issuance; `08` checks each order's plugin | Re-issue with `-Plugin EasyDNSFix` |
| DNS creds swapped / stale / rate-limited (identical 420 over HTTP 200) | `02` live-verifies and auto-corrects; plugin paces calls; one issuance at a time | Re-run `02` with the current pair; wait out rate limits |
| Renewal task runs as the wrong account and renews nothing | `-TaskUser` = the account that ran `02`; first-run smoke test | Re-register the task |

---

## Verification checklist (per host)

```bash
openssl s_client -connect <host>:443 -servername <fqdn> </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
# issuer must be Let's Encrypt (NOT "(STAGING)"); subject = <fqdn>; dates = new window
```

- [ ] Staging dry run passed for every zone before any production issuance
- [ ] Production LE account created and valid
- [ ] Every automated host has a `CertHosts.ps1` entry; every excluded host has a commented-out entry with the reason
- [ ] `.\07-Renew-And-Deploy.ps1 -WhatIfIssue` reports nothing to issue
- [ ] Each host serves the LE cert end to end (and completes a real login where auth is involved)
- [ ] Remote-push credentials stored in the vault and `Test-WSMan` passes for every push target
- [ ] Exchange: 443 **and** 25/STARTTLS serve the new thumbprint (from outside and from an internal host); no event 12014; hybrid `TlsCertificateName` updated
- [ ] Appliances on native ACME / acme.sh have an external expiry probe and no orchestrator entry
- [ ] Scheduled task enabled, runs `07`, smoke-tested
- [ ] Monitoring alerts on `RESULT: FAILED` **and** on a stale `last-run.json`; external expiry probe live
- [ ] Previous certs removed only **after** their replacement is verified; cert entries only, never keys
- [ ] Secrets in the vault (service account profile), not email or shared drives
