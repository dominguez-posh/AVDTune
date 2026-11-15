# Registers a scheduled task "AVDTune CTO" that runs autostart.ps1 at sign-in of the current user.
# Run once by hand: powershell -File .claude\team\install-autostart.ps1   (remove: Unregister-ScheduledTask "AVDTune CTO")
$script = Join-Path $PSScriptRoot 'autostart.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName 'AVDTune CTO' -Action $action -Trigger $trigger -Settings $settings -Description 'Starts the AVDTune CTO session at sign-in' -Force | Out-Null
Write-Host 'Task "AVDTune CTO" registered.'
