# letsencrypt-recipe - https://github.com/Signal-Point-Technologies/letsencrypt-recipe
# Author : Andrew Cohen, Signal Point Technologies
# License: MIT
<#
=====================================================================
 EasyDNSFix - corrected Posh-ACME DNS plugin for easyDNS
=====================================================================
 WHY THIS EXISTS
   The built-in 'EasyDNS' plugin finds the zone by querying candidate
   names "until successful" - but easyDNS returns its errors (unknown
   zone, rate limit, bad creds) as HTTP 200 with an error JSON body.
   The built-in plugin therefore "finds" the first candidate it tries
   (e.g. _acme-challenge.host.example.com), writes the TXT into a
   nonexistent zone, and validation fails with NXDOMAIN.
   Confirmed against the live rest.easydns.net API.

 WHAT THIS PLUGIN DOES DIFFERENTLY
   - Treats a response containing .error as a FAILURE even on HTTP 200
   - Requires a real record list (.data) before accepting a zone
   - Sleeps 1.5s before every API call (easyDNS hard limit: 1 req/sec)
   - Throws a clear message on 420 (rate limit / bad creds)

 INSTALL (one time, on the orchestrator)
   1. New-Item -ItemType Directory -Force C:\ProgramData\Posh-ACME-Plugins
   2. Copy this file there.
   3. [Environment]::SetEnvironmentVariable('POSHACME_PLUGINS',
          'C:\ProgramData\Posh-ACME-Plugins','Machine')
   4. Open a NEW pwsh window (env var is read when Posh-ACME loads).
   5. Verify:  Get-PAPlugin | Where-Object Name -eq EasyDNSFix

 USE (identical args to the built-in plugin)
   $pArgs = @{
     EDToken = (Get-Secret EasyDNS-Token -AsPlainText)
     EDKey   = (Get-Secret EasyDNS-Key -AsPlainText)
   }
   New-PACertificate web01.example.com -Plugin EasyDNSFix `
       -PluginArgs $pArgs -DnsSleep 120 -Verbose
=====================================================================
#>

function Get-CurrentPluginType { 'dns-01' }

function Invoke-EasyDnsFixApi {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers,
        [string]$Method = 'GET',
        [string]$Body
    )
    # easyDNS hard limit is 1 request/second - always pace ourselves
    Start-Sleep -Milliseconds 1500

    $params = @{ Uri = $Uri; Method = $Method; Headers = $Headers; ErrorAction = 'Stop' }
    if ($Body) { $params.Body = $Body; $params.ContentType = 'application/json' }
    $resp = Invoke-RestMethod @params @script:UseBasic

    # easyDNS serves errors as HTTP 200 with an error object in the body
    if ($resp.PSObject.Properties['error']) {
        if ($resp.error.code -eq 420) {
            throw "easyDNS 420 'Enhance Your Calm': rate limited OR credentials not accepted. Wait before retrying. ($Uri)"
        }
        throw "easyDNS API error $($resp.error.code): $($resp.error.message) ($Uri)"
    }
    return $resp
}

function Find-EasyDnsFixZone {
    param(
        [Parameter(Mandatory)][string]$RecordName,
        [Parameter(Mandatory)][string]$ApiBase,
        [Parameter(Mandatory)][hashtable]$Headers
    )
    $pieces = $RecordName.Split('.')
    # Start at index 1: the full record name itself is never the zone for
    # an _acme-challenge record, and skipping it saves a rate-limited call.
    for ($i = 1; $i -lt ($pieces.Count - 1); $i++) {
        $zoneTest = $pieces[$i..($pieces.Count - 1)] -join '.'
        Write-Verbose "EasyDNSFix: testing zone candidate '$zoneTest'"
        try {
            $resp = Invoke-EasyDnsFixApi -Uri "$ApiBase/zones/records/all/$zoneTest`?format=json" -Headers $Headers
            # Only a genuine zone answer has a .data record list
            if ($resp.PSObject.Properties['data']) {
                Write-Verbose "EasyDNSFix: confirmed zone '$zoneTest'"
                return @{ Zone = $zoneTest; Records = $resp.data }
            }
        } catch {
            if ($_.Exception.Message -match '420') { throw }   # don't walk through a rate limit
            Write-Verbose "EasyDNSFix: '$zoneTest' rejected ($($_.Exception.Message))"
        }
    }
    throw "EasyDNSFix: no zone found for $RecordName - check the account can see the zone and creds are current."
}

function Add-DnsTxt {
    [CmdletBinding(DefaultParameterSetName='Secure')]
    param(
        [Parameter(Mandatory, Position=0)][string]$RecordName,
        [Parameter(Mandatory, Position=1)][string]$TxtValue,
        [Parameter(Mandatory)][string]$EDToken,
        [Parameter(ParameterSetName='Secure', Mandatory)][securestring]$EDKeySecure,
        [Parameter(ParameterSetName='DeprecatedInsecure', Mandatory)][string]$EDKey,
        [switch]$EDUseSandbox,
        [Parameter(ValueFromRemainingArguments)]$ExtraParams
    )
    if ($EDKeySecure) { $EDKey = [pscredential]::new('a',$EDKeySecure).GetNetworkCredential().Password }
    $script:UseBasic = if ('UseBasicParsing' -in (Get-Command Invoke-RestMethod).Parameters.Keys) { @{UseBasicParsing=$true} } else { @{} }

    $apiBase = if ($EDUseSandbox) { 'https://sandbox.rest.easydns.net' } else { 'https://rest.easydns.net' }
    $headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${EDToken}:${EDKey}")) }

    $zoneInfo = Find-EasyDnsFixZone -RecordName $RecordName -ApiBase $apiBase -Headers $headers
    $zoneName = $zoneInfo.Zone
    $shortName = ($RecordName -ireplace [regex]::Escape(".$zoneName"), '')
    if ($shortName -eq $RecordName) { $shortName = '@' }

    # Skip if an identical TXT already exists
    $existing = $zoneInfo.Records | Where-Object { $_.host -eq $shortName -and $_.type -eq 'TXT' -and $_.rdata -eq $TxtValue }
    if ($existing) {
        Write-Verbose "EasyDNSFix: TXT $RecordName with this value already exists - nothing to do"
        return
    }

    Write-Verbose "EasyDNSFix: adding TXT '$shortName' to zone '$zoneName'"
    $body = @{ domain=$zoneName; host=$shortName; ttl=300; prio=0; type='TXT'; rdata=$TxtValue } | ConvertTo-Json
    $resp = Invoke-EasyDnsFixApi -Uri "$apiBase/zones/records/add/$zoneName/txt?format=json" -Headers $headers -Method PUT -Body $body
    if ($resp.status -ne 201) {
        throw "EasyDNSFix: add TXT returned unexpected status $($resp.status): $($resp | ConvertTo-Json -Compress)"
    }
    Write-Verbose "EasyDNSFix: TXT created (id $($resp.data.id))"

    <#
    .SYNOPSIS
        Adds a DNS TXT record via the easyDNS REST API (fixed zone detection).
    .DESCRIPTION
        Drop-in replacement for the built-in EasyDNS plugin that correctly
        detects easyDNS's HTTP-200-wrapped error responses and paces calls
        to respect the 1 request/second rate limit.
    #>
}

function Remove-DnsTxt {
    [CmdletBinding(DefaultParameterSetName='Secure')]
    param(
        [Parameter(Mandatory, Position=0)][string]$RecordName,
        [Parameter(Mandatory, Position=1)][string]$TxtValue,
        [Parameter(Mandatory)][string]$EDToken,
        [Parameter(ParameterSetName='Secure', Mandatory)][securestring]$EDKeySecure,
        [Parameter(ParameterSetName='DeprecatedInsecure', Mandatory)][string]$EDKey,
        [switch]$EDUseSandbox,
        [Parameter(ValueFromRemainingArguments)]$ExtraParams
    )
    if ($EDKeySecure) { $EDKey = [pscredential]::new('a',$EDKeySecure).GetNetworkCredential().Password }
    $script:UseBasic = if ('UseBasicParsing' -in (Get-Command Invoke-RestMethod).Parameters.Keys) { @{UseBasicParsing=$true} } else { @{} }

    $apiBase = if ($EDUseSandbox) { 'https://sandbox.rest.easydns.net' } else { 'https://rest.easydns.net' }
    $headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${EDToken}:${EDKey}")) }

    $zoneInfo = Find-EasyDnsFixZone -RecordName $RecordName -ApiBase $apiBase -Headers $headers
    $zoneName = $zoneInfo.Zone
    $shortName = ($RecordName -ireplace [regex]::Escape(".$zoneName"), '')
    if ($shortName -eq $RecordName) { $shortName = '@' }

    $rec = $zoneInfo.Records | Where-Object { $_.host -eq $shortName -and $_.type -eq 'TXT' -and $_.rdata -eq $TxtValue }
    if (-not $rec) {
        Write-Verbose "EasyDNSFix: TXT $RecordName with this value not found - nothing to remove"
        return
    }
    foreach ($r in @($rec)) {
        Write-Verbose "EasyDNSFix: deleting TXT id $($r.id) from zone '$zoneName'"
        Invoke-EasyDnsFixApi -Uri "$apiBase/zones/records/$zoneName/$($r.id)?format=json" -Headers $headers -Method DELETE | Out-Null
    }

    <#
    .SYNOPSIS
        Removes a DNS TXT record via the easyDNS REST API (fixed zone detection).
    #>
}

function Save-DnsTxt {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments)]$ExtraParams
    )
    # easyDNS commits changes immediately - nothing to save

    <#
    .SYNOPSIS
        Not required for easyDNS; changes commit immediately.
    #>
}
