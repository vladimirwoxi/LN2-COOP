# Test driver for the v0.6 player-2 input bridge.
#
# Runs against the isolated copy G:\LN2\test-install, never the user's game.
# It installs mod\Scripts\main.lua, starts the game, walks to the Wilderness
# level, then feeds bridge_test.txt (see main.lua) to move player 2 without hands
# on the second pad. Screenshots and the mod log are left in G:\LN2\local.
#
# Run (needs full file access, the game and its logs live outside the workspace):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_bridge.ps1
#
# -Mode pad: do not write bridge_test.txt; just launch, wait and collect logs so a
#            human can move the second gamepad.

param(
    [ValidateSet("auto", "pad", "quick", "jump")][string]$Mode = "auto",
    [int]$PadSeconds = 12,
    [string]$Bin = "G:\LN2\test-install\Helios\Binaries\Win64",
    [string]$OutDir = "G:\LN2\local"
)

$ErrorActionPreference = "Stop"

$exeName = "Little_Nightmares_II_Enhanced-Win64-Shipping"
$exe = Join-Path $Bin "$exeName.exe"
$mod = Join-Path $Bin "ue4ss\Mods\LN2Coop"
$log = Join-Path $mod "LN2Coop.log"
$testFile = Join-Path $mod "bridge_test.txt"
$winPs1 = Join-Path $OutDir "win.ps1"
$src = Join-Path $PSScriptRoot "..\mod\Scripts\main.lua"

function Say($msg) { Write-Host ("[bridge-test] " + $msg) }

function Wait-Log([string]$pattern, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $log) {
            $text = [System.IO.File]::ReadAllText($log)
            if ($text -match $pattern) { return $true }
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Shot([string]$name) {
    $out = Join-Path $OutDir ("bridge-" + $name + ".png")
    & powershell -NoProfile -ExecutionPolicy Bypass -File $winPs1 -Action shot -Out $out | Out-Null
    Say ("screenshot " + $out)
}

function Set-Test([string]$values) {
    [System.IO.File]::WriteAllText($testFile, $values + "`r`n", (New-Object System.Text.ASCIIEncoding))
    Say ("test drive -> " + $values)
}

if (-not (Test-Path $exe)) { throw "game exe not found: $exe" }
if (-not (Test-Path $src)) { throw "mod source not found: $src (run from wip\v0.6-bridge)" }
if (-not (Test-Path $winPs1)) { throw "win.ps1 not found: $winPs1" }

Say "stopping any running game"
Get-Process -Name $exeName -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

Say "installing mod into $mod"
New-Item -ItemType Directory -Force -Path $mod | Out-Null
Copy-Item $src (Join-Path $mod "Scripts\main.lua") -Force
[System.IO.File]::WriteAllText((Join-Path $mod "coop.cfg"), "on`r`n", (New-Object System.Text.ASCIIEncoding))
Remove-Item $testFile -ErrorAction SilentlyContinue
Remove-Item $log -ErrorAction SilentlyContinue
Remove-Item (Join-Path $mod "LN2Coop.log.prev") -ErrorAction SilentlyContinue

# only the co-op mod, no diagnostics
$modsTxt = Join-Path $Bin "ue4ss\Mods\mods.txt"
[System.IO.File]::WriteAllText($modsTxt, "LN2Coop : 1`r`n", (New-Object System.Text.ASCIIEncoding))

Say "starting the game"
Start-Process $exe -WorkingDirectory $Bin

$deadline = (Get-Date).AddSeconds(150)
while ((Get-Date) -lt $deadline) {
    $p = Get-Process -Name $exeName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($p) { break }
    Start-Sleep -Milliseconds 500
}
if (-not $p) { throw "game window did not appear" }
Say ("game window up, pid " + $p.Id)

if (-not (Wait-Log "LVL_MainMenu" 180)) {
    Say "WARNING: main menu not seen in the log; trying ENTER anyway"
}
& powershell -NoProfile -ExecutionPolicy Bypass -File $winPs1 -Action keys -Keys ENTER | Out-Null
Say "sent ENTER at the menu"

if (-not (Wait-Log "PLVL_" 240)) { throw "gameplay level did not load (see $log)" }
Say "gameplay level is in"
if (-not (Wait-Log "input bridge: resolved" 60)) { Say "WARNING: input bridge did not resolve keys" }
if (-not (Wait-Log "player 2 placed on player 1" 60)) { Say "WARNING: player 2 was not placed" }

# the game pauses when it loses focus; bring it forward and resume
& powershell -NoProfile -ExecutionPolicy Bypass -File $winPs1 -Action keys -Keys ENTER | Out-Null
Start-Sleep -Seconds 2

if ($Mode -eq "auto") {
    Say "auto test: forward"
    Set-Test "0,1"
    Start-Sleep -Seconds 3
    Shot "forward"

    Say "auto test: back"
    Set-Test "0,-1"
    Start-Sleep -Seconds 2

    Say "auto test: strafe right"
    Set-Test "1,0"
    Start-Sleep -Seconds 2

    Say "auto test: camera right"
    Set-Test "0,0,0.4,0"
    Start-Sleep -Milliseconds 1500
    Shot "camera"

    Say "auto test: jump"
    Set-Test "0,0,0,0,1"
    Start-Sleep -Milliseconds 350
    Shot "jump"
    Set-Test "0,0"
    Start-Sleep -Seconds 1

    Say "auto test: stop"
    Set-Test "0,0"
    Start-Sleep -Seconds 1
} elseif ($Mode -eq "quick") {
    Say "quick test: forward for 4 s"
    Set-Test "0,1"
    Start-Sleep -Seconds 4
    Shot "quick"
} elseif ($Mode -eq "jump") {
    Say "jump test: jump, then press A again in the air (must not stack)"
    Set-Test "0,0,0,0,1"
    Start-Sleep -Milliseconds 250
    Set-Test "0,0"
    Start-Sleep -Milliseconds 100
    Set-Test "0,0,0,0,1"
    Start-Sleep -Milliseconds 250
    Set-Test "0,0"
    Start-Sleep -Seconds 1
    Shot "jump"
} else {
    Say ("pad test: move the LEFT stick on gamepad 2 now, " + $PadSeconds + " seconds")
    Start-Sleep -Seconds $PadSeconds
    Shot "pad"
}

Remove-Item $testFile -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Shot "final"

Say "stopping the game to flush the log"
Get-Process -Name $exeName -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

if (Test-Path $log) {
    Copy-Item $log (Join-Path $OutDir "bridge-test.log") -Force
    Say "log copied to $(Join-Path $OutDir 'bridge-test.log')"
    Say "----- interesting log lines -----"
    Select-String -Path $log -Pattern "world ->|create player|player 2 placed|stepped aside|ClientRestart|input bridge|bridge state|test drive|switching to direct|jump|p2 state" |
        ForEach-Object { $_.Line } | Select-Object -Last 80
} else {
    Say "no log was written"
}
