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

# Where Godot might be. Reported verbatim when nothing turns up, because "not
# found" without saying where it looked is a message that helps nobody.
$script:GodotSearched = @()

function Find-GodotIn {
    param([string] $Dir)
    $script:GodotSearched += $Dir
    if (-not (Test-Path $Dir)) { return $null }
    # The console build by preference: the plain one detaches from the terminal
    # and prints nowhere, which makes every later problem invisible. Mono builds
    # are skipped - nothing here needs C#.
    foreach ($pattern in @("Godot_v*_console.exe", "Godot_v*.exe", "godot.exe", "Godot.exe")) {
        $hit = Get-ChildItem -LiteralPath $Dir -Filter $pattern -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -notlike "*mono*" } |
               Sort-Object Name | Select-Object -Last 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Find-Godot {
    if ($env:GODOT) {
        if (Test-Path $env:GODOT) { return $env:GODOT }
        Write-Warning "GODOT is set to '$env:GODOT' but nothing is there; ignoring it."
    }

    foreach ($name in @("godot", "godot4", "Godot")) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }

    # winget installs Godot as a portable package, which does not land in
    # Programs at all - it goes under Microsoft\WinGet\Packages in a folder
    # named after the package id. And without administrator rights winget
    # cannot create its command-line aliases, so `godot` is not on PATH either.
    # Between the two, a perfectly good install is invisible to every obvious
    # place to look.
    $wingetPkgs = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
    if (Test-Path $wingetPkgs) {
        foreach ($sub in (Get-ChildItem -LiteralPath $wingetPkgs -Directory -ErrorAction SilentlyContinue)) {
            if ($sub.Name -notlike "*odot*") { continue }
            $hit = Find-GodotIn $sub.FullName
            if ($hit) { return $hit }
        }
    }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links"),
        (Join-Path $env:LOCALAPPDATA "Programs\Godot"),
        (Join-Path $env:LOCALAPPDATA "Godot"),
        (Join-Path $env:APPDATA "Godot"),
        (Join-Path $env:ProgramFiles "Godot"),
        (Join-Path ${env:ProgramFiles(x86)} "Godot"),
        (Join-Path $env:USERPROFILE "scoop\apps\godot\current"),
        (Join-Path $env:USERPROFILE "Downloads"),
        (Join-Path $env:USERPROFILE "Desktop")
    ) | Where-Object { $_ }

    foreach ($d in $candidates) {
        $hit = Find-GodotIn $d
        if ($hit) { return $hit }
    }

    # Last resort: one level down, covering a versioned or unzipped folder.
    foreach ($d in @((Join-Path $env:LOCALAPPDATA "Programs"), (Join-Path $env:USERPROFILE "Downloads"))) {
        if (-not (Test-Path $d)) { continue }
        foreach ($sub in (Get-ChildItem -LiteralPath $d -Directory -ErrorAction SilentlyContinue)) {
            if ($sub.Name -notlike "*odot*") { continue }
            $hit = Find-GodotIn $sub.FullName
            if ($hit) { return $hit }
        }
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
    Write-Host "Godot was not found. Looked in:" -ForegroundColor Yellow
    foreach ($d in $script:GodotSearched) { Write-Host "  $d" }
    Write-Host ""
    Write-Host "Point GODOT at the binary and run again, for example:"
    Write-Host ""
    Write-Host '  $env:GODOT = "$env:LOCALAPPDATA\Programs\Godot\Godot_v4.7.1-stable_win64_console.exe"'
    Write-Host "  powershell -ExecutionPolicy Bypass -File tools/run_launcher.ps1"
    Write-Host ""
    Write-Host "Or install it:  winget install GodotEngine.GodotEngine"
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
