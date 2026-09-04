<#
.SYNOPSIS
    Registers the Scheduled Task that runs the Halo Response Agent every 10 minutes, 24/7.
.DESCRIPTION
    Run this once, as Administrator, after Invoke-HaloResponseAgent.ps1, config.json,
    classifier-prompt.md, and resolver-prompt.md are in place. Re-run it to update
    the task if you change the interval, script path, or -RequireApproval.
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
#>

param(
    # Defaults to Invoke-HaloResponseAgent.ps1 sitting next to this script - as long
    # as you keep the deployed files together, this needs no editing either.
    [string]$ScriptPath = (Join-Path $PSScriptRoot "Invoke-HaloResponseAgent.ps1"),
    [int]$IntervalMinutes = 10,
    [switch]$RequireApproval
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
