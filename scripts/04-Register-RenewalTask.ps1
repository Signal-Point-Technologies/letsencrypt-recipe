# letsencrypt-recipe - https://github.com/Signal-Point-Technologies/letsencrypt-recipe
# Author : Andrew Cohen, Signal Point Technologies
# License: MIT
<#
=====================================================================
 PART 4 of 4 - Create the daily unattended renewal scheduled task
=====================================================================
 RUN AS   : A local administrator, ELEVATED, in pwsh 7
 RUN ONCE : Yes (re-running replaces the existing task)

 WHAT IT DOES
   Registers a daily 3:00 AM scheduled task that runs
   07-Renew-And-Deploy.ps1 under the SERVICE ACCOUNT (elevated):
   Submit-Renewal -AllOrders plus the per-host deploy hooks, so a
   renewed cert is also IMPORTED and BOUND, not just issued.
   Posh-ACME only actually renews orders inside their renewal window
   (~60 days), so a daily run is cheap and safe.

 !!! CRITICAL !!!
   The -TaskUser you give here MUST be the exact account that ran
   02-Setup-Vault-Account.ps1. Posh-ACME state + the secret vault live
   in that profile. Any other account = task "succeeds" but renews
   nothing (empty state).

 LOGGING
   Appends to C:\ProgramData\Posh-ACME-Renewal\renewal.log
   Check it after the first scheduled run; runbook Phase 9 wires
   failures to your alerting (Teams/email webhook, syslog, etc.).

 EXAMPLE
   PS C:\> .\04-Register-RenewalTask.ps1 -TaskUser 'CONTOSO\svc-acme'
   Password for CONTOSO\svc-acme: ********

   # Different schedule:
   PS C:\> .\04-Register-RenewalTask.ps1 -TaskUser 'CONTOSO\svc-acme' -At '04:30'

   # Test immediately after creating (watch the log):
   PS C:\> Start-ScheduledTask -TaskName 'ACME-Renewal'
   PS C:\> Get-Content C:\ProgramData\Posh-ACME-Renewal\renewal.log -Tail 30

 NOTE ON LE_PROD
   The task targets LE_PROD because production certs are what must
   auto-renew. Harmless to create the task before your first prod
   cert exists - until then each run simply finds nothing to renew.
=====================================================================
#>

#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory)][string]$TaskUser,   # e.g. 'CONTOSO\svc-acme'
    [string]$At = '03:00',
    [string]$TaskName = 'ACME-Renewal',
    # Folder holding 07-Renew-And-Deploy.ps1 (+ 05/06 it calls).
    # Defaults to wherever THIS script lives.
    [string]$ScriptsPath = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

$logDir = 'C:\ProgramData\Posh-ACME-Renewal'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$pwshExe = (Get-Command pwsh -ErrorAction Stop).Source

# The task runs 07-Renew-And-Deploy.ps1: Submit-Renewal + per-host deploy
# hooks + RESULT: OK/FAILED logging (Phase 9 alerting greps for FAILED).
$runner = Join-Path $ScriptsPath '07-Renew-And-Deploy.ps1'
if (-not (Test-Path $runner)) { throw "07-Renew-And-Deploy.ps1 not found in '$ScriptsPath' - copy the scripts folder there or pass -ScriptsPath." }

$action  = New-ScheduledTaskAction -Execute $pwshExe -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runner`""
$trigger = New-ScheduledTaskTrigger -Daily -At $At
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
    -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 30)

Write-Host "Enter the password for $TaskUser (needed to register a task that runs whether logged on or not):"
$cred = Get-Credential -UserName $TaskUser -Message "Password for scheduled task account"

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -User $cred.UserName -Password $cred.GetNetworkCredential().Password -RunLevel Highest -Force | Out-Null

Write-Host ""
Write-Host "Task '$TaskName' registered: daily at $At as $TaskUser" -ForegroundColor Green
Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State | Format-Table -AutoSize

Write-Host "VERIFY NOW:" -ForegroundColor Yellow
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Yellow
Write-Host "  Get-Content $logDir\renewal.log -Tail 30" -ForegroundColor Yellow
Write-Host ""
Write-Host "Expected on first run (before any prod certs): a header line +" -ForegroundColor Yellow
Write-Host "'RESULT: OK' with nothing to renew. Errors about missing account" -ForegroundColor Yellow
Write-Host "mean the task user is NOT the account that ran Part 2." -ForegroundColor Yellow
