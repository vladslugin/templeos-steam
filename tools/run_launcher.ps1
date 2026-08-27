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
    [int]    $BridgePort = 4556,
    [int]    $QmpPort = 4444,
    [int]    $BootTimeout = 180
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
    # A launcher left over from a previous run holds the bridge port, and the
    # symptom is nothing like the cause: the new run cannot bind, so it reports
    # that it could not open a port, while the old one sits there invisibly
    # with no window. Matched on the project path so a Godot editor someone has
    # open on something else is left alone.
    Get-CimInstance Win32_Process -Filter "Name like '%Godot%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*host*temple*" } | ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
        }
    Get-CimInstance Win32_Process -Filter "Name like '%python%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*qemu_drive*" -or $_.CommandLine -like "*combridge*" } | ForEach-Object {
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

    # Hardware acceleration, with emulation behind it if the host cannot.
    #
    # WHPX used to abort during boot with an assertion in QEMU's x86 decoder,
    # and the CPU model was blamed because the CPU model was the only thing
    # being varied. It was kernel_irqchip=off - taken from Terry's published
    # script - held constant across every attempt. Leave the interrupt
    # controller in the hypervisor partition and QEMU never has to decode the
    # instruction that touches it. A hundred million iterations of a HolyC loop
    # took 0.400s emulated and 0.064s accelerated.
    #
    # Asked for by name rather than left to default: WHPX's default is
    # allowed-not-required, so on a host without an in-partition APIC it would
    # quietly fall back to the arrangement that crashes.
    #
    # The whpx:tcg list is the fallback. Windows Hypervisor Platform is not on
    # every machine, and a player without it should get a slow game rather than
    # no game.
    $qemuArgs = @(
        "-machine", "pc,kernel_irqchip=on,accel=whpx:tcg",
        # Not host and not max. Both are fatal under WHPX in the worst way:
        # QEMU stays up, logs "Unexpected VP exit code 4", and the guest never
        # initialises its display - so this would hang on a black window
        # instead of failing.
        "-cpu", "qemu64",
        # Two cores, not more. Under emulation extra cores are actively harmful
        # - four measured 13 FPS at the desktop against two cores' 26 - and
        # accelerated they buy nothing measurable. Two rather than one because
        # a campaign task needs a second core to exist.
        "-smp", "cores=2",
        "-m", "2048",
        "-rtc", "base=localtime",
        "-drive", "file=$Disk,format=$diskFmt,index=0,media=disk",
        "-qmp", "tcp:127.0.0.1:$QmpPort,server,nowait",
        # The guest dials out to us rather than listening. As a server its
        # serial socket takes one client for the life of the guest, so the
        # second launcher of a session gets a refused connection and no bridge.
        # This way the host listens and the guest keeps knocking once a second,
        # so closing the launcher and opening it again just works.
        # Declared as a chardev rather than with the -serial shorthand. The
        # shorthand accepts reconnect-ms and then exits anyway the moment the
        # peer goes away; this form actually reconnects, which is the point.
        "-chardev", "socket,id=com1,host=127.0.0.1,port=$ComPort,reconnect-ms=1000",
        "-serial", "chardev:com1",
        "-vnc", "127.0.0.1:$vncDisplay",
        "-display", "none"
    )

    # The guest dials out, and the emulator exits if a connection attempt is
    # refused - the first one or any later one. So something has to hold that
    # port for the whole session while launchers come and go, and that is
    # combridge: it takes the guest's connection on one port and re-serves the
    # conversation on another, which is the one everything else talks to.
    Remove-Item "build\bridge_ready.txt" -ErrorAction SilentlyContinue
    Start-Process -FilePath "python" -WindowStyle Hidden `
        -ArgumentList @("tools\combridge.py", "--guest-port", "$ComPort",
                        "--client-port", "$BridgePort",
                        "--ready-file", "build\bridge_ready.txt") `
        -RedirectStandardOutput "build\combridge.log" `
        -RedirectStandardError  "build\combridge.err" | Out-Null

    $bound = $false
    for ($i = 0; $i -lt 100; $i++) {
        if (Test-Path "build\bridge_ready.txt") { $bound = $true; break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $bound) {
        Write-Error "could not open the bridge ports. See build\combridge.err"
        exit 1
    }

    Write-Host "Guest   : starting"
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
    Start-Sleep -Seconds 3

    # Two prompts stand between power-on and a usable desktop and a player
    # should see neither: Terry's boot menu, which is a factory-image problem
    # still to be solved, and the first-run offer of a tour.
    #
    # The menu comes up immediately, so it is answered on a short timer. What
    # follows is not timed at all. The game layer is the last thing start-up
    # runs and the first thing it does is speak, so waiting for that line waits
    # exactly as long as this machine needs - which turned a flat ninety-five
    # second sleep into about eight.
    Add-Content "build\mon_queue.txt" -Encoding ascii -Value @("sleep 3", "keys 1")

    $booted = & python "tools\wait_guest.py" --port $BridgePort --timeout $BootTimeout
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Guest   : desktop up in $booted s"
    } else {
        Write-Host "Guest   : no word from the layer after $BootTimeout s; going on anyway" -ForegroundColor Yellow
        Write-Host "          (see build\launcher_qemu.err, and check /Game is on the disk)"
    }

    # The tour prompt is typed into a user terminal by HomeSys.HC's StartUpTasks
    # through XTalk, so it can land a moment after the layer is already talking.
    Add-Content "build\mon_queue.txt" -Encoding ascii -Value @("sleep 2", "keys n", "sleep 2")
    Start-Sleep -Seconds 6
} else {
    Write-Host "Guest   : attaching to one already running"
}

# ----------------------------------------------------------- the launcher

& $godot --headless --path "host\temple" --import 2>&1 | Out-Null

$args = @("--path", "host\temple")
if ($Headless) { $args += "--headless" }
$args += "--"
$args += @("--bridge-port", "$BridgePort", "--vnc-port", "$VncPort")
if ($Check -ne "") { $args += @("--check", $Check) }

Write-Host "Launcher: starting"
Write-Host ""
& $godot @args
exit $LASTEXITCODE
