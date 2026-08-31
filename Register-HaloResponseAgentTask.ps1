<#
.SYNOPSIS
    Registers the Scheduled Task that runs the Halo Response Agent every 10 minutes, 24/7.
.DESCRIPTION
    Run this once, as Administrator, after Invoke-HaloResponseAgent.ps1, config.json,
    and agent-prompt.md are in place. Re-run it to update the task if you change the
    interval or script path.
#>

param(
    # Defaults to Invoke-HaloResponseAgent.ps1 sitting next to this script - as long
    # as you keep the deployed files together, this needs no editing either.
    [string]$ScriptPath = (Join-Path $PSScriptRoot "Invoke-HaloResponseAgent.ps1"),
    [int]$IntervalMinutes = 10
)

$taskName = "Altec Halo Response Agent"

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration ([TimeSpan]::MaxValue)

# Run as a service account so it works whether or not anyone is logged in.
# Swap to a dedicated gMSA/service account if you have one instead of SYSTEM.
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -DontStopOnIdleEnd `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description "Runs the Altec Halo Response Agent every $IntervalMinutes minutes, 24/7." `
    -Force

Write-Host "Scheduled task '$taskName' registered - runs every $IntervalMinutes minutes."
