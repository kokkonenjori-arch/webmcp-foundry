# bin/install_autostart.ps1 — register the public supervisor to start at user logon (Windows).
#
#   powershell -ExecutionPolicy Bypass -File bin\install_autostart.ps1          # install
#   powershell -ExecutionPolicy Bypass -File bin\install_autostart.ps1 -Remove  # uninstall
#
# The task runs bin/serve_public.sh under Git Bash, which keeps the Julia server and the public
# tunnels alive and republishes the stable entry page when URLs rotate. Reversible.
param([switch]$Remove)
$name = "WebMCP Foundry public"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$bash = "C:\Program Files\Git\bin\bash.exe"
if (-not (Test-Path $bash)) { $bash = (Get-Command bash.exe).Source }
if ($Remove) { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue; Write-Host "removed task '$name'"; exit 0 }
$posix = ($root -replace '\\', '/') -replace '^([A-Za-z]):', '/$1'
$posix = $posix.Substring(0,1) + $posix.Substring(1,1).ToLower() + $posix.Substring(2)
$arg = "-lc `"cd $posix && bash bin/serve_public.sh`""
$action = New-ScheduledTaskAction -Execute $bash -Argument $arg -WorkingDirectory $root
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Write-Host "installed task '$name' (at logon, restarts on failure): `"$bash`" $arg"
Write-Host "start it now with:  Start-ScheduledTask -TaskName `"$name`""
