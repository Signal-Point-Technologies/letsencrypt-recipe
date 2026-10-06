# Microsoft Tunnel Gateway - Let's Encrypt with acme.sh

Unattended Let's Encrypt for a **Microsoft Tunnel Gateway** (Intune / Defender for Endpoint VPN) running on Linux. The cert is issued and renewed **on the gateway itself** by `acme.sh` using DNS-01, then loaded with `mst-cli import_cert`.

Tested on RHEL 9 with the podman-based Tunnel server, `acme.sh` + `dns_easydns`, Let's Encrypt RSA-2048.

> **One issuer per name.** If you also run the Windows orchestrator from this repo, keep the tunnel name **commented out** in `CertHosts.ps1`. Two issuers for one name burn the Let's Encrypt duplicate-certificate limit (5 per week).

---

## How MS Tunnel actually loads its certificate

This is the part the vendor docs gloss over. Read it before you touch anything.

| File | Role |
|---|---|
| `/etc/mstunnel/certs/site.crt` + `/etc/mstunnel/private/site.key` | **Input** (PEM). What you drop in. |
| `/etc/mstunnel/private/site.pfx` | **Input** (PKCS#12). **Preferred over the PEM pair if it exists.** |
| `/etc/mstunnel/certs/active.crt` + `/etc/mstunnel/private/active.key` | **Output** of `mst-cli import_cert`. **What the server actually serves.** |

- Writing `site.crt`/`site.key` changes nothing on its own. You must run `mst-cli import_cert` and then `mst-cli server restart`.
- **If a `site.pfx` is lying around** (typically from the original install with a commercial cert), `import_cert` uses it instead of your PEM pair and prompts `Enter Import Password:`. With the wrong or blank password you get `Mac verify error: invalid password?`. **Move the old `site.pfx` out of the way.** With no PFX present, `import_cert` reads the PEM pair and does not prompt.
- **`mst-cli import_cert` exits 0 even when it fails.** `import_cert && server restart` will still restart after a failed import. Always check the served cert afterwards.
- The health command is `mst-cli server status` (there is no `server show`).
- The restart drops every active tunnel session for roughly 20-60 seconds. Do cutovers in a quiet window.

---

## Prerequisites

- Root on the gateway (`sudo` may not be installed on a minimal Tunnel box - log in as root).
- A **direct SSH session**. Don't run interactive `mst-cli` through an RMM's browser SSH proxy: without a real TTY the password prompt gets garbage and the restart can fail, taking the tunnel down.
- DNS API credentials for the zone (examples use easyDNS; any `acme.sh` DNS hook works).
- The gateway's public name, e.g. `tunnel.example.com`, already set in the Intune Tunnel **Server Configuration**. No Intune change is needed per rotation as long as the FQDN stays the same.

---

## Step 1 - Get DNS credentials onto the gateway (without exposing them)

If the credentials live in a PowerShell SecretManagement vault on a Windows orchestrator, pipe them straight across SSH. They never hit the screen, clipboard or Windows disk.

**1a. Key-based SSH from the orchestrator to the gateway.** Run on the orchestrator **as the account that owns the vault**:

```powershell
# PowerShell 7: '""' is passed literally and becomes a 2-character passphrase. Use '' instead.
if (!(Test-Path ~/.ssh/id_ed25519)) { ssh-keygen -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" }
Get-Content ~/.ssh/id_ed25519.pub
```

> If you already created the key with `-N '""'` and SSH asks for a passphrase, the passphrase is literally `""`. Remove it with `ssh-keygen -p -f "$HOME/.ssh/id_ed25519" -P '""' -N ''`.

On the gateway (root), paste the **whole** public key line between the quotes:

```bash
umask 077; mkdir -p /root/.ssh
echo 'ssh-ed25519 AAAA...your-key... user@orchestrator' >> /root/.ssh/authorized_keys
restorecon -R /root/.ssh                       # RHEL/SELinux: without this sshd silently ignores the file
ssh-keygen -lf /root/.ssh/authorized_keys      # compare fingerprint with the orchestrator's
sshd -T | grep -i permitrootlogin              # 'without-password'/'prohibit-password' or 'yes' = key login OK
```

Test from the orchestrator: `ssh root@<gateway-ip> hostname` should return without a prompt.

**1b. Push the credentials** (orchestrator, same account):

```powershell
$t = Get-Secret EasyDNS-Token -AsPlainText; $k = Get-Secret EasyDNS-Key -AsPlainText
"export EASYDNS_Token='$t'`nexport EASYDNS_Key='$k'`n" |
  ssh root@<gateway-ip> "umask 077; cat > /root/.dns.env"
Remove-Variable t,k
```

On the gateway, strip Windows line endings and check the values without printing them:

```bash
sed -i 's/\r$//; /^$/d' /root/.dns.env
source /root/.dns.env; echo "token len=${#EASYDNS_Token} key len=${#EASYDNS_Key}"   # both non-zero
```

No vault? Type the `export` lines by hand with a leading space (`HISTCONTROL=ignorespace`) so they stay out of shell history.

---

## Step 2 - Back up the current certificate

```bash
mst-cli server status
openssl x509 -in /etc/mstunnel/certs/site.crt -noout -subject -issuer -dates
ls -la /etc/mstunnel/certs /etc/mstunnel/private

B=/root/mstunnel-cert-backup-$(date +%F); mkdir -p $B
cp -p /etc/mstunnel/certs/site.crt /etc/mstunnel/private/site.key $B/
cp -p /etc/mstunnel/certs/active.crt /etc/mstunnel/private/active.* $B/ 2>/dev/null
ls -l $B
```

Leave the file modes alone (`rwxrwx---` on the key is normal - the container's group reads it). `acme.sh --install-cert` overwrites in place and keeps the existing mode.

---

## Step 3 - Install acme.sh and issue (safe at any hour)

Issuing only writes under `~/.acme.sh`. It does not touch the tunnel.

```bash
curl https://get.acme.sh | sh -s email=<your-contact-email>
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# Staging first - proves DNS-01 works without spending production rate limit
~/.acme.sh/acme.sh --issue --dns dns_easydns -d tunnel.example.com --keylength 2048 --staging
openssl x509 -in ~/.acme.sh/tunnel.example.com/tunnel.example.com.cer -noout -issuer   # contains (STAGING)

# Production
~/.acme.sh/acme.sh --issue --dns dns_easydns -d tunnel.example.com --keylength 2048 --server letsencrypt --force
openssl x509 -in ~/.acme.sh/tunnel.example.com/tunnel.example.com.cer -noout -issuer -dates   # LE issuer, no STAGING
```

RSA-2048 is the safest choice for the Defender Tunnel clients.

---

## Step 4 - Cut over (quiet window - this restarts the tunnel)

```bash
# Remove the stale PFX or import_cert will ignore your PEM files
[ -f /etc/mstunnel/private/site.pfx ] && mv /etc/mstunnel/private/site.pfx $B/site.pfx.old

~/.acme.sh/acme.sh --install-cert -d tunnel.example.com \
  --key-file       /etc/mstunnel/private/site.key \
  --fullchain-file /etc/mstunnel/certs/site.crt \
  --reloadcmd      "printf '\n' | mst-cli import_cert && mst-cli server restart"
```

- `--install-cert` copies the files **and runs the reload immediately**, so this is the restart.
- The reload command is saved and re-run by cron on every renewal. `printf '\n' |` guarantees it can never hang on a prompt.
- **Paste nothing after `mst-cli import_cert` when running it by hand** - it reads stdin and swallows the following lines, so they never run.

---

## Step 5 - Verify

```bash
mst-cli server status                                                        # State: running, Health: healthy
openssl s_client -connect 127.0.0.1:443 -servername tunnel.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -dates                                       # LE issuer, ~90 days
ls -la /etc/mstunnel/certs/active.crt /etc/mstunnel/private/active.key       # today's date
printf '\n' | mst-cli import_cert </dev/null; echo rc=$?                     # cron-style run: no prompt, no Mac error
crontab -l | grep acme                                                       # renewal cron present
grep ReloadCmd ~/.acme.sh/tunnel.example.com/tunnel.example.com.conf         # base64; decode to confirm
```

If the served issuer is still the old CA, `active.*` was not regenerated: check for a `site.pfx` and re-run `mst-cli import_cert` by hand.

Finally, connect an Intune-enrolled device with the Defender Tunnel client and check the cert from outside.

---

## Step 6 - Clean up

```bash
grep -c EASYDNS ~/.acme.sh/account.conf && shred -u /root/.dns.env   # expect 2: acme.sh saved the creds for renewals
chmod 600 ~/.acme.sh/account.conf
```

Optional: remove the orchestrator's key from `/root/.ssh/authorized_keys` if you don't want ongoing access.

---

## Rollback

```bash
B=/root/mstunnel-cert-backup-<date>
cp -p $B/active.crt /etc/mstunnel/certs/; cp -p $B/active.key /etc/mstunnel/private/
cp -p $B/site.crt /etc/mstunnel/certs/;   cp -p $B/site.key /etc/mstunnel/private/
mst-cli server restart
```

Abandoning the cutover entirely? Also run `~/.acme.sh/acme.sh --remove -d tunnel.example.com` so cron stops renewing.

If the server won't start after a failed reload:

```bash
journalctl -u mstunnel-server -n 50 --no-pager
podman ps -a
podman logs mstunnel-server 2>&1 | tail -30
```

---

## Operating notes

- **Renewal:** cron fires several times a day. acme.sh renews about 30 days before expiry (or per the CA's ARI window) and restarts the tunnel at whatever hour that happens - normally overnight.
- **Shared DNS API budget:** the gateway and any orchestrator share the DNS provider's request limits (easyDNS: 1 req/s, 500/day). Never loop retries.
- **Credential rotation:** the DNS credentials now live in two places - the orchestrator's vault **and** the gateway's `~/.acme.sh/account.conf`. Rotating them means updating both, or tunnel renewals start failing quietly about 60 days later.
- **Monitoring:** watch the served expiry from outside (any HTTPS expiry probe). A failed renewal on the box doesn't report to the orchestrator.
- **Root password:** if the gateway's root password isn't on record, set one (`passwd root`) and store it while you have the session open.
