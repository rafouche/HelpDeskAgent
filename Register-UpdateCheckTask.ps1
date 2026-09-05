<#
.SYNOPSIS
    Registers the Scheduled Task that checks for and pulls a new commit
    every so often, separate from the every-10-minute ticket-processing
    task.
.DESCRIPTION
    Run this once, as Administrator, after Update-HaloResponseAgent.ps1 is
    in place. Re-run it to update the task if you change the interval or
    script path.

    Before relying on this, confirm `git` actually resolves for the SYSTEM
    account, the same way `claude` and the MCP config once didn't (see
    CLAUDE.md's "Known limitations" - this project has hit that exact shape
    of bug three times already for other tools). Trigger this task manually
    once (Task Scheduler -> right-click -> Run) and check
    logs\update-<date>.log for an ERROR line before trusting it on its own
    schedule - don't assume an interactive `git pull` working for you proves
    anything about what SYSTEM sees.
.PARAMETER ScriptPath
    Defaults to Update-HaloResponseAgent.ps1 sitting next to this script -
    as long as you keep the deployed files together, this needs no editing
    either.
.PARAMETER IntervalMinutes
    How often to check for a new commit. Defaults to 30 - there's no need
    for this to run as often as the 10-minute ticket-processing task, since
    a new commit typically only ships a handful of times a day at most.
#>

param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot "Update-HaloResponseAgent.ps1"),
    [int]$IntervalMinutes = 30
)

$taskName = "Altec Halo Response Agent - Auto Update"
$taskArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

# Same reasoning as Register-HaloResponseAgentTask.ps1's -WorkingDirectory:
# this script uses $PSScriptRoot to find its own repo, which resolves
# correctly regardless of Task Scheduler's default working directory - but
# setting this too keeps both tasks consistent and avoids relying on that
# alone if the script is ever copied/adjusted.
$taskWorkingDirectory = Split-Path -Path $ScriptPath -Parent

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskArguments -WorkingDirectory $taskWorkingDirectory

# No -RepetitionDuration: on Windows 10/Server 2016+, omitting it is how you
# get an indefinitely-repeating trigger - see Register-HaloResponseAgentTask.ps1's
# own note on this for the real error hit when this used [TimeSpan]::MaxValue
# instead.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)

# Same account as the main task, for the same reason - see
# Register-HaloResponseAgentTask.ps1's own comment on this.
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -DontStopOnIdleEnd `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description "Checks for and pulls a new commit to this folder every $IntervalMinutes minutes." `
    -Force

Write-Host "Scheduled task '$taskName' registered - checks every $IntervalMinutes minutes." -ForegroundColor Green
Write-Host "`nBefore trusting this on its own schedule: trigger it manually once (Task" -ForegroundColor Yellow
Write-Host "Scheduler -> right-click -> Run) and check logs\update-<today>.log for an" -ForegroundColor Yellow
Write-Host "ERROR line - confirms git actually works for SYSTEM, not just interactively" -ForegroundColor Yellow
Write-Host "as you. No log file/no ERROR line at all just means nothing needed pulling," -ForegroundColor Yellow
Write-Host "which is the expected quiet case - this script only logs when something" -ForegroundColor Yellow
Write-Host "actually happened." -ForegroundColor Yellow
