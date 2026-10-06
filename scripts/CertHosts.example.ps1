# letsencrypt-recipe - https://github.com/Signal-Point-Technologies/letsencrypt-recipe
# Author : Andrew Cohen, Signal Point Technologies
# License: MIT
<#
=====================================================================
 CertHosts.ps1 - the certificate inventory for 07-Renew-And-Deploy.ps1
=====================================================================
 COPY THIS FILE TO  CertHosts.ps1  (same folder) AND EDIT.
 CertHosts.ps1 is git-ignored; this example is the documented template.

 07-Renew-And-Deploy.ps1 dot-sources CertHosts.ps1 at startup and
 expects it to define ONE variable: $CertHosts, an array of hashtables.

 KEYS PER ENTRY
   Domain        (required) primary name; also the Posh-ACME order name.
   Names         SAN list submitted to Let's Encrypt. Defaults to @(Domain).
                 Every extra SAN is another DNS-01 challenge that can fail
                 unattended - only add names something actually uses.
   Deploy        scriptblock taking the domain; MUST THROW on failure.
                 Runs after every issue/renew. Failure = RESULT: FAILED.
   DeployNote    set alongside Deploy when the hook does only PART of
                 the job (e.g. a store push with no binding). Logged as
                 a PARTIAL notice every run so the rest stays visible.
   DeployPending set INSTEAD of Deploy when the cert is issued here but
                 deployed elsewhere / by hand. Logged NOTICE, run stays OK.
   Hold          a reason string. The host is listed in the inventory
                 report but NOT issued (no CA call). Run stays OK.
                 Release with -IssueOnly <fqdn> or delete the line.
   PushTarget    (remote store push) FQDN of the machine to push the
                 cert + private key into over WinRM. Nothing is bound.
   PushSecrets   (remote store push) vault secret name(s) holding a
                 PSCredential with local-admin rights on PushTarget.
                 Tried in order, so a shared fallback works:
                   Set-Secret -Name Web02-Cred -Secret (Get-Credential)
                   Set-Secret -Name WinRM-Cred -Secret (Get-Credential)
   ExchangeBind  (Exchange only) $true = after the push, bind the cert
                 for IIS,SMTP and re-pin the receive connectors (see
                 Invoke-ExchangeBind in 07). Default $false = store only.
   ExchangeConnectors (Exchange only, optional) receive connector names
                 to re-pin, without the 'SERVER' prefix. Default is
                 'Default Frontend <SERVER>'. List EVERY :25 connector
                 that can answer a TLS client (e.g. an internal relay
                 connector with internal RemoteIPRanges).

 THINGS AVAILABLE INSIDE A Deploy SCRIPTBLOCK
   $PSScriptRoot            this folder (05/06 live here)
   $HostByDomain[<fqdn>]    this entry (lower-case key)
   Push-CertToRemoteStore   -Domain -Target -VaultSecretNames
   Invoke-ExchangeBind      -Target -Thumbprint -Sni -VaultSecretNames
                            [-ReceiveConnector <names>]

 Keep this file pure ASCII (no smart quotes / em-dashes) - Windows
 PowerShell 5.1 reads BOM-less UTF-8 as ANSI and chokes on them.
=====================================================================
#>

$CertHosts = @(

    # ---- Pattern 1: LOCAL IIS host (this machine IS the orchestrator) ----
    # Fully automated: import into LocalMachine\My, remove superseded cert
    # ENTRIES (never keys), rebind the IIS site to the new thumbprint.
    @{
        Domain = 'web01.example.com'
        Names  = @('web01.example.com')
        Deploy = {
            param([string]$Domain)
            & (Join-Path $PSScriptRoot '05-Import-CertToStore.ps1') `
                -MainDomain $Domain -InstallChain -RemoveSuperseded -Confirm:$false | Out-Null
            & (Join-Path $PSScriptRoot '06-Bind-IISCert.ps1') -Domain $Domain -Confirm:$false | Out-Null
            # SNI-bound site instead of Default Web Site *:443 ?
            # & (Join-Path $PSScriptRoot '06-Bind-IISCert.ps1') -Domain $Domain `
            #     -SiteName 'MySite' -HostHeader $Domain -Confirm:$false | Out-Null
        }
    }

    # ---- Pattern 2: REMOTE store push, binding still manual ----
    # Cert + private key land in the target's LocalMachine\My over WinRM.
    # Nothing is bound or restarted, so the service is untouched. The
    # DeployNote keeps the missing binding step visible every run.
    @{
        Domain      = 'portal.example.com'
        Names       = @('portal.example.com')
        DeployNote  = 'store-only push to web02.example.com; IIS SNI binding still manual'
        PushTarget  = 'web02.example.com'
        PushSecrets = @('Web02-Cred', 'WinRM-Cred')
        Deploy = {
            param([string]$Domain)
            $e = $HostByDomain[$Domain.ToLower()]
            Push-CertToRemoteStore -Domain $Domain -Target $e.PushTarget `
                -VaultSecretNames $e.PushSecrets | Out-Null
        }
    }

    # ---- Pattern 3: Exchange - store push, then (opt-in) auto-bind ----
    # Stage 1 (always): cert + key pushed into the Exchange server's store.
    # Stage 2 (ExchangeBind = $true): Invoke-ExchangeBind - revocation
    #   pre-check on the server, Enable-ExchangeCertificate -Services
    #   IIS,SMTP by thumbprint, re-pin TlsCertificateName on each listed
    #   receive connector, verify 443 + 25/STARTTLS on the wire.
    # WHEN TO FLIP ExchangeBind TO $true: only after the FIRST bind + port-25
    #   re-pin has been done and verified by hand (09-Bind-ExchangeCert.ps1,
    #   runbook Exchange phase), the server's revocation check passes
    #   (plain-HTTP egress to the CA's CRL host works), and any hybrid
    #   Get-HybridConfiguration TlsCertificateName pin is updated. Until then
    #   every run logs a PARTIAL notice so the manual step stays visible.
    # PushSecrets must hold a DOMAIN account in Organization Management.
    @{
        Domain       = 'mail.example.com'
        Names        = @('mail.example.com', 'smtp.example.com')
        ExchangeBind = $false
        # ExchangeConnectors = @('Default Frontend EXCH01', 'Internal Relay')
        PushTarget   = 'exch01.corp.example.net'
        PushSecrets  = @('Exch01-Cred', 'WinRM-Cred')
        Deploy = {
            param([string]$Domain)
            $e = $HostByDomain[$Domain.ToLower()]
            $r = Push-CertToRemoteStore -Domain $Domain -Target $e.PushTarget `
                    -VaultSecretNames $e.PushSecrets
            if ($e.ExchangeBind) {
                $bind = @{ Target = $e.PushTarget; Thumbprint = $r.Thumbprint; Sni = $Domain; VaultSecretNames = $e.PushSecrets }
                if ($e.ExchangeConnectors) { $bind.ReceiveConnector = $e.ExchangeConnectors }
                Invoke-ExchangeBind @bind
            } else {
                $n = "NOTICE: $Domain deploy is PARTIAL - store-only push to $($e.PushTarget); ExchangeBind is off (flip after the manual cutover)"
                Log $n
                $script:Status.Notices += $n
            }
        }
    }

    # ---- Pattern 4: issue only; deploy is manual / a later phase ----
    # The cert is issued and renewed here; someone still installs it.
    @{
        Domain        = 'vpn1.example.net'
        Names         = @('vpn1.example.net')
        DeployPending = 'FortiGate REST API push not built yet - see runbook'
    }

    # ---- Pattern 5: on hold - listed, not issued ----
    @{
        Domain        = 'appliance.example.net'
        Names         = @('appliance.example.net')
        Hold          = 'approach undecided (vendor API vs guided manual upload)'
        DeployPending = 'manual upload via the appliance admin UI'
    }

    # ---- EXCLUDED BY DECISION - keep commented out WITH the reason ----
    # vpn1.example.net (alt) - if the appliance has NATIVE ACME (e.g. FortiOS),
    #   let it renew itself and never also issue the name here. Monitor its
    #   expiry separately (native ACME usually needs HTTP-01 on port 80).
    # tunnel.example.net (alt) - box runs acme.sh locally; same rule.
    #   Microsoft Tunnel Gateway is this case - see docs/MS-TUNNEL-GATEWAY.md.
    # tunnel.example.net - managed appliance; the vendor issues its own cert.
    #   Two issuers for one name burn the LE duplicate-certificate limit.
    # @{ Domain='tunnel.example.net'; DeployPending='vendor-managed' }
)
