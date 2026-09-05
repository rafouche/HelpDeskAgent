<#
.SYNOPSIS
    Registers the Scheduled Task that runs the Halo Response Agent every 10
    minutes, 24/7 - and, optionally, the separate task that checks for and
    pulls a new commit on its own schedule.
.DESCRIPTION
    Run this once, as Administrator, after Install-Prerequisites.ps1 has
    been run and Invoke-HaloResponseAgent.ps1, config.json,
    classifier-prompt.md, and resolver-prompt.md are in place. Re-run it to
    update either task if you change an interval, a script path,
    -RequireApproval, or -EnableAutoUpdate.
.PARAMETER RequireApproval
    Bake -RequireApproval into the scheduled task's own arguments, so every
    scheduled run starts in human-approval mode (see Invoke-HaloResponseAgent.ps1's
    -RequireApproval and README's "Human approval mode" section) instead of running
    fully live from the first scheduled firing. config.json's
    halo.ai_waiting_approval_status_name/ai_approved_status_name must already be
    set to real Halo statuses before the task runs, same requirement as running the
    switch by hand. Once comfortable with what's coming out of approval mode,
    re-run this script without -RequireApproval to switch the existing task back to
    running fully live - no need to delete and recreate it.
.PARAMETER EnableAutoUpdate
    Also register a second scheduled task that runs Update-HaloResponseAgent.ps1
    on its own schedule (see -UpdateCheckIntervalMinutes), checking GitHub for
    changed files and downloading them over plain HTTPS (no git - this
    deployment is downloaded files, not a git clone) so this deployment
    stays current without someone re-downloading files by hand. Kept as its
    own task, not folded into the main one, so a network problem can never
    abort a real ticket-processing cycle. Off by default. Omitting this
    switch on a later re-run never touches the update task either way - it
    doesn't add it if missing, and doesn't remove it if already registered;
    use `Unregister-ScheduledTask -TaskName "Altec Halo Response Agent - Auto Update"`
    directly if you want it gone.
.PARAMETER UpdateCheckIntervalMinutes
    How often the auto-update task checks for changed files, if
    -EnableAutoUpdate is passed. Defaults to 30 - there's no need for this
    to run as often as the ticket-processing task, since a new commit
    typically only ships a handful of times a day at most.
#>

param(
    # Defaults to Invoke-HaloResponseAgent.ps1 sitting next to this script - as long
    # as you keep the deployed files together, this needs no editing either.
    [string]$ScriptPath = (Join-Path $PSScriptRoot "Invoke-HaloResponseAgent.ps1"),
    [int]$IntervalMinutes = 10,
    [switch]$RequireApproval,
    [switch]$EnableAutoUpdate,
    [int]$UpdateCheckIntervalMinutes = 30
)

$taskName = "Altec Halo Response Agent"

$taskArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
if ($RequireApproval) { $taskArguments += " -RequireApproval" }

# WorkingDirectory matters here, not just cosmetics: Task Scheduler gives a
# process no working directory of its own by default (it lands in
# %SystemRoot%\System32), and claude's own project-scoped MCP config
# (.mcp.json, per README's "Register each MCP server" section) is discovered
# from the CURRENT DIRECTORY, not from -File's path or $PSScriptRoot - those
# only tell PowerShell where the .ps1 file itself lives, not where the `claude`
# child process launches from. Without this, every registered MCP tool would
# silently be invisible under the SYSTEM account this task runs as, even
# though the exact same command works fine when run interactively from this
# folder - the same silent-failure shape as the original Server:tool naming
# bug (see CLAUDE.md's "Known limitations"), just a different root cause.
$taskWorkingDirectory = Split-Path -Path $ScriptPath -Parent

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskArguments -WorkingDirectory $taskWorkingDirectory

# No -RepetitionDuration: on Windows 10/Server 2016+, omitting it is how you
# get an indefinitely-repeating trigger. Passing [TimeSpan]::MaxValue there
# (an earlier version of this script did) instead serializes to the task XML
# duration "P99999999DT23H59M59S", which Register-ScheduledTask rejects
# outright with "task XML contains a value which is incorrectly formatted or
# out of range" - confirmed via a real run hitting that exact error, and via
# Microsoft's own Q&A on this exact symptom (not assumed).
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)

# Run as a service account so it works whether or not anyone is logged in.
# Swap to a dedicated gMSA/service account if you have one instead of SYSTEM.
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -DontStopOnIdleEnd `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

$taskDescription = "Runs the Altec Halo Response Agent every $IntervalMinutes minutes, 24/7."
if ($RequireApproval) {
    $taskDescription += " Human-approval mode (-RequireApproval): every reply/action waits for sign-off in Halo."
}

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description $taskDescription `
    -Force

Write-Host "Scheduled task '$taskName' registered - runs every $IntervalMinutes minutes."
if ($RequireApproval) {
    Write-Host "Human-approval mode is ON: every scheduled run passes -RequireApproval." -ForegroundColor Yellow
    Write-Host "Confirm config.json's ai_waiting_approval_status_name/ai_approved_status_name are set" -ForegroundColor Yellow
    Write-Host "to real Halo statuses first, or the task will fail every run - see README's" -ForegroundColor Yellow
    Write-Host "'Human approval mode' section. Re-run this script without -RequireApproval later" -ForegroundColor Yellow
    Write-Host "to switch the task back to running fully live." -ForegroundColor Yellow
}
else {
    Write-Host "Running fully live (no -RequireApproval) - re-run this script with -RequireApproval" -ForegroundColor DarkGray
    Write-Host "to switch the task to human-approval mode instead." -ForegroundColor DarkGray
}

if ($EnableAutoUpdate) {
    $updateTaskName = "Altec Halo Response Agent - Auto Update"
    $updateScriptPath = Join-Path $taskWorkingDirectory "Update-HaloResponseAgent.ps1"
    $updateTaskArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$updateScriptPath`""

    $updateAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $updateTaskArguments -WorkingDirectory $taskWorkingDirectory

    # Same reasoning as the main trigger above: no -RepetitionDuration is
    # how you get an indefinitely-repeating trigger on Windows 10/Server
    # 2016+.
    $updateTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes $UpdateCheckIntervalMinutes)

    $updateSettings = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -DontStopOnIdleEnd `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    Register-ScheduledTask -TaskName $updateTaskName -Action $updateAction -Trigger $updateTrigger `
        -Principal $principal -Settings $updateSettings `
        -Description "Checks GitHub for changed files and downloads them every $UpdateCheckIntervalMinutes minutes." `
        -Force

    Write-Host "`nScheduled task '$updateTaskName' registered - checks every $UpdateCheckIntervalMinutes minutes." -ForegroundColor Green
    Write-Host "Trigger it manually once (Task Scheduler -> right-click -> Run) and check" -ForegroundColor Yellow
    Write-Host "logs\update-<today>.log for an ERROR line before trusting it on its own" -ForegroundColor Yellow
    Write-Host "schedule - confirms SYSTEM has outbound internet access to GitHub. No log" -ForegroundColor Yellow
    Write-Host "file at all is the expected quiet outcome when there's nothing new to fetch -" -ForegroundColor Yellow
    Write-Host "this script only logs when something actually happened." -ForegroundColor Yellow
}
else {
    Write-Host "`nAuto-update task not registered - re-run with -EnableAutoUpdate to add it." -ForegroundColor DarkGray
}
