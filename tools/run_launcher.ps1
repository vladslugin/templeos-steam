# run_launcher.ps1 - start the guest and the launcher, in one command.
#
# The PowerShell twin of run_launcher.sh, and the one to use on Windows. Typing
# `bash` in PowerShell finds whichever bash comes first on PATH, and on a normal
# Windows install that is WSL's launcher - which fails with "execvpe /bin/bash
# failed" when no distribution is installed. Nothing here needs bash, so this
# sidesteps the question.
#
#   .\tools\run_launcher.ps1                  open the launcher in a window
#   .\tools\run_launcher.ps1 -Check hc_fib    run one task check and report
#   .\tools\run_launcher.ps1 -Attach          a guest is already running
#
# It can be run from anywhere; paths are worked out from the script's location.

[CmdletBinding()]
param(
    [string] $Check = "",
    [switch] $Attach,
    [switch] $Headless,
    [string] $Disk = "build\temple_disk.raw",
    [int]    $VncPort = 5909,
    [int]    $ComPort = 4555,
    [int]    $QmpPort = 4444,
    [int]    $BootWait = 95
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

if ($Check -ne "") { $Headless = $true }

# ------------------------------------------------------------------- tooling

function Find-Godot {
    if ($env:GODOT -and (Test-Path $env:GODOT)) { return $env:GODOT }

    $onPath = Get-Command godot -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    $dir = Join-Path $env:LOCALAPPDATA "Programs\Godot"
    if (Test-Path $dir) {
        # The console build, by preference: the plain one detaches from the
        # terminal and prints nowhere, which makes every problem invisible.
        $c = Get-ChildItem $dir -Filter "Godot_v*_console.exe" -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -notlike "*mono*" } | Sort-Object Name | Select-Object -Last 1
        if ($c) { return $c.FullName }
        $c = Get-ChildItem $dir -Filter "Godot_v*.exe" -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -notlike "*mono*" } | Sort-Object Name | Select-Object -Last 1
        if ($c) { return $c.FullName }
        $c = Join-Path $dir "godot.exe"
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Find-Qemu {
    $onPath = Get-Command qemu-system-x86_64 -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    foreach ($d in @("$env:ProgramFiles\qemu", "${env:ProgramFiles(x86)}\qemu")) {
        $c = Join-Path $d "qemu-system-x86_64.exe"
        if (Test-Path $c) { return $c }
    }
    return $null
}

$godot = Find-Godot
if (-not $godot) {
    Write-Error @"
Godot was not found.

Point `$env:GODOT at it, for example:

  `$env:GODOT = "`$env:LOCALAPPDATA\Programs\Godot\Godot_v4.7.1-stable_win64_console.exe"

or install it:  winget install GodotEngine.GodotEngine
"@
    exit 1
}
Write-Host "Godot   : $godot"

$qemu = Find-Qemu
if (-not $qemu) {
    Write-Error "QEMU was not found. Install it:  winget install SoftwareFreedomConservancy.QEMU"
    exit 1
}

if (-not (Test-Path $Disk)) {
    Write-Error "No disk image at $Disk. Install one first, see the README."
    exit 1
}

# --------------------------------------------------------------- the guest

function Stop-Stale {
    Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | ForEach-Object {
        try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {}
    }
    Get-CimInstance Win32_Process -Filter "Name like '%python%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*qemu_drive*" } | ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
        }
    Start-Sleep -Seconds 2
}

if (-not $Attach) {
    Stop-Stale
    New-Item -ItemType Directory -Force -Path "build" | Out-Null

    # RFB display numbers, not TCP ports: :0 is 5900.
    $vncDisplay = $VncPort - 5900

    # Name the format rather than letting QEMU probe it. Probing works, but then
    # QEMU refuses writes to block 0 as a precaution - and block 0 is the MBR,
    # which is exactly what installing a boot loader has to write.
    if ($Disk -like "*.qcow2") { $diskFmt = "qcow2" } else { $diskFmt = "raw" }

    # TCG rather than WHPX: QEMU 11.1 aborts on this guest during boot with an
    # assertion in the x86 decoder, with every CPU model. TCG holds ~30 FPS,
    # which is what the guest's window manager targets anyway.
    $qemuArgs = @(
        "-machine", "pc,kernel_irqchip=off",
        "-accel", "tcg",
        "-cpu", "qemu64",
        "-smp", "cores=4",
        "-m", "2048",
        "-rtc", "base=localtime",
        "-drive", "file=$Disk,format=$diskFmt,index=0,media=disk",
        "-qmp", "tcp:127.0.0.1:$QmpPort,server,nowait",
        "-serial", "tcp:127.0.0.1:$ComPort,server,nowait",
        "-vnc", "127.0.0.1:$vncDisplay",
        "-display", "none"
    )

    Write-Host "Guest   : starting (about $BootWait s under emulation)"
    Start-Process -FilePath $qemu -ArgumentList $qemuArgs -WindowStyle Hidden `
        -RedirectStandardOutput "build\launcher_qemu.log" `
        -RedirectStandardError  "build\launcher_qemu.err" | Out-Null

    # Wait for QMP rather than guessing, so a slow machine is not a race.
    $listening = $false
    for ($i = 0; $i -lt 60; $i++) {
        $c = Get-NetTCPConnection -LocalPort $QmpPort -State Listen -ErrorAction SilentlyContinue
        if ($c) { $listening = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $listening) {
        Write-Error "QEMU never opened its QMP port. See build\launcher_qemu.err"
        exit 1
    }

    "" | Set-Content "build\mon_queue.txt" -Encoding ascii
    Remove-Item "build\mon_out.txt" -ErrorAction SilentlyContinue

    # --queue and --out belong to the serve subcommand and have to follow it.
    Start-Process -FilePath "python" -WindowStyle Hidden `
        -ArgumentList @("tools\qemu_drive.py", "--port", "$QmpPort", "serve",
                        "--queue", "build\mon_queue.txt", "--out", "build\mon_out.txt") `
        -RedirectStandardOutput "build\launcher_drive.log" `
        -RedirectStandardError  "build\launcher_drive.err" | Out-Null
    Start-Sleep -Seconds 4

    # Two prompts stand between power-on and a usable desktop and a player
    # should see neither: Terry's boot menu, which is a factory-image problem
    # still to be solved, and the first-run offer of a tour.
    $wait = $BootWait - 15
    Add-Content "build\mon_queue.txt" -Encoding ascii -Value @(
        "sleep 6", "keys 1", "sleep $wait", "keys n", "sleep 4"
    )
    Start-Sleep -Seconds $BootWait
} else {
    Write-Host "Guest   : attaching to one already running"
}

# ----------------------------------------------------------- the launcher

& $godot --headless --path "host\temple" --import 2>&1 | Out-Null

$args = @("--path", "host\temple")
if ($Headless) { $args += "--headless" }
$args += "--"
if ($Check -ne "") { $args += @("--check", $Check) }

Write-Host "Launcher: starting"
Write-Host ""
& $godot @args
exit $LASTEXITCODE
