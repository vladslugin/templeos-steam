# stop_all.ps1 - shut down everything this project starts.
#
# There are four processes in a running session - the emulator, the monitor
# driver, the serial bridge and the launcher - and leaving any one of them
# behind breaks the next run in a way that does not look like the cause. A
# forgotten launcher holds the bridge port, so the next one reports that it
# could not open a port. A forgotten bridge holds it too, and then the guest
# talks to a process nobody is reading. Both cost an hour the first time.
#
#   powershell -ExecutionPolicy Bypass -File tools/stop_all.ps1
#
# Godot is matched on the project path rather than by name, so an editor open
# on something else is left alone.

$ErrorActionPreference = "SilentlyContinue"

$killed = 0

function Stop-Matching {
    param([string] $NameLike, [string] $CmdLike, [string] $What)
    $procs = Get-CimInstance Win32_Process -Filter "Name like '$NameLike'"
    foreach ($p in $procs) {
        if ($CmdLike -ne "" -and $p.CommandLine -notlike $CmdLike) { continue }
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            Write-Host ("  stopped {0} (pid {1})" -f $What, $p.ProcessId)
            $script:killed++
        } catch {}
    }
}

Write-Host "Stopping everything this project starts:"
Stop-Matching "%qemu-system%" ""                  "emulator"
Stop-Matching "%python%"      "*qemu_drive*"      "monitor driver"
Stop-Matching "%python%"      "*combridge*"       "serial bridge"
Stop-Matching "%python%"      "*wait_guest*"      "boot waiter"
Stop-Matching "%Godot%"       "*host*temple*"     "launcher"

if ($killed -eq 0) {
    Write-Host "  nothing was running"
}
Start-Sleep -Seconds 2
