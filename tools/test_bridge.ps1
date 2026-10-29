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
# -Mode pickup: RT picks the nearest PickupComponent (test radius 2000), walk with
#            the item, RT again puts it down.

param(
    [ValidateSet("auto", "pad", "quick", "jump", "sprint", "anim", "pose", "pad1", "pose2", "pose3", "pose4", "pose5", "pose6", "pickup")][string]$Mode = "auto",
    [int]$PadSeconds = 12,
    [string]$Bin = "G:\LN2\test-install\Helios\Binaries\Win64",
    [string]$OutDir = "G:\LN2\local",
    [string]$SaveRoot = "G:\LN2\save-test",
    # screenshots make the game lose focus (and pause), so log-only runs skip them
    [switch]$NoShots
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

function Set-IniValue([string]$path, [string]$key, [string]$value) {
    if (-not (Test-Path $path)) { return }
    $text = [System.IO.File]::ReadAllText($path)
    $rx = "(?m)^\s*" + [regex]::Escape($key) + "\s*=.*$"
    if ($text -match $rx) {
        $text = [regex]::Replace($text, $rx, "$key=$value")
    } else {
        $text = $text.TrimEnd() + "`r`n$key=$value`r`n"
    }
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

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
    if ($NoShots) { return }
    $out = Join-Path $OutDir ("bridge-" + $name + ".png")
    & powershell -NoProfile -ExecutionPolicy Bypass -File $winPs1 -Action shot -Out $out -MinConsole | Out-Null
    Say ("screenshot " + $out)
}

function Set-Test([string]$values) {
    [System.IO.File]::WriteAllText($testFile, $values + "`r`n", (New-Object System.Text.ASCIIEncoding))
    Say ("test drive -> " + $values)
}

if (-not (Test-Path $exe)) { throw "game exe not found: $exe" }
if (-not (Test-Path $src)) { throw "mod source not found: $src (run from wip\v0.6-bridge)" }
if (-not (Test-Path $winPs1)) { throw "win.ps1 not found: $winPs1" }

# The game resolves its save folder through the shell API, not %LOCALAPPDATA%, so the only
# reliable way to keep the user's progress out of a test is to swap the folder itself:
# back the real one up, seed it with the test checkpoint, and put the backup back afterwards.
$realUserSaved = Join-Path $env:USERPROFILE "AppData\Local\Helios\Saved"
$userSaveGames = Join-Path $realUserSaved "SaveGames"
$saveBackup = "G:\LN2\save-user-backup"
$testSaved = Join-Path $SaveRoot "Helios\Saved"
$saveRestored = $false

function Restore-UserSave {
    if ($script:saveRestored) { return }
    if (-not $SaveRoot) { return }
    if (-not (Test-Path $saveBackup)) { return }
    Get-Process -Name $exeName -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3
    Remove-Item $realUserSaved -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item $saveBackup $realUserSaved -Recurse -Force
    $script:saveRestored = $true
    Say "user save/config restored from $saveBackup"
}

# a terminating error must still put the user's save back
trap {
    Say ("ERROR: " + $_)
    Restore-UserSave
    & powershell -NoProfile -ExecutionPolicy Bypass -File $winPs1 -Action restore | Out-Null
    exit 1
}

Say "stopping any running game"
Get-Process -Name $exeName -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

Say "installing mod into $mod"
New-Item -ItemType Directory -Force -Path $mod | Out-Null
Copy-Item $src (Join-Path $mod "Scripts\main.lua") -Force
[System.IO.File]::WriteAllText((Join-Path $mod "coop.cfg"), "on`r`n", (New-Object System.Text.ASCIIEncoding))
Remove-Item $testFile -ErrorAction SilentlyContinue
Remove-Item $log -ErrorAction SilentlyContinue
Remove-Item (Join-Path $mod "api_dump.txt") -ErrorAction SilentlyContinue
Remove-Item (Join-Path $mod "anim_dump.txt") -ErrorAction SilentlyContinue
Remove-Item (Join-Path $mod "LN2Coop.log.prev") -ErrorAction SilentlyContinue

# only the co-op mod, no diagnostics
$modsTxt = Join-Path $Bin "ue4ss\Mods\mods.txt"
[System.IO.File]::WriteAllText($modsTxt, "LN2Coop : 1`r`n", (New-Object System.Text.ASCIIEncoding))

# Give the test the known checkpoint and windowed settings, keeping the user's own files aside.
if ($SaveRoot) {
    if (Test-Path $saveBackup) { Remove-Item $saveBackup -Recurse -Force }
    Copy-Item $realUserSaved $saveBackup -Recurse -Force
    Say "user save/config backed up to $saveBackup"
    if (Test-Path (Join-Path $testSaved "SaveGames")) {
        Remove-Item (Join-Path $userSaveGames "*") -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item (Join-Path $testSaved "SaveGames\*") $userSaveGames -Force
        Say "test checkpoint seeded into the real save folder"
    } else {
        Say ("WARNING: no test checkpoint in " + $testSaved)
    }

    # windowed mode for tests: the user asked to run the game in a window
    $gus = Join-Path $realUserSaved "Config\WindowsNoEditor\GameUserSettings.ini"
    Set-IniValue $gus "FullscreenMode" "2"
    Set-IniValue $gus "LastConfirmedFullscreenMode" "2"
    Set-IniValue $gus "PreferredFullscreenMode" "2"
    Set-IniValue $gus "ResolutionSizeX" "1280"
    Set-IniValue $gus "ResolutionSizeY" "720"
    Say "game set to windowed 1280x720"
}

Say "starting the game"
Start-Process $exe -ArgumentList "-windowed", "-ResX=1280", "-ResY=720" -WorkingDirectory $Bin

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

# The menu needs a key press, and the press only lands while the game window has the
# focus, which is flaky in a headless run: try a few times before giving up.
$levelLoaded = $false
for ($attempt = 1; $attempt -le 6; $attempt++) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $winPs1 -Action keys -Keys ENTER -MinConsole | Out-Null
    Say ("sent ENTER at the menu (attempt " + $attempt + ")")
    if (Wait-Log "PLVL_" 40) { $levelLoaded = $true; break }
}
if (-not $levelLoaded) { throw "gameplay level did not load (see $log)" }
Say "gameplay level is in"
if (-not (Wait-Log "input bridge: resolved" 60)) { Say "WARNING: input bridge did not resolve keys" }
if (-not (Wait-Log "player 2 placed on player 1" 60)) { Say "WARNING: player 2 was not placed" }

# the game pauses when it loses focus; bring it forward and resume
& powershell -NoProfile -ExecutionPolicy Bypass -File $winPs1 -Action keys -Keys ENTER -MinConsole | Out-Null
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
} elseif ($Mode -eq "sprint") {
    Say "sprint test: forward with X held (test-drive sprint flag)"
    Set-Test "0,1,0,0,0,1"
    Start-Sleep -Seconds 4
    Shot "sprint"
} elseif ($Mode -eq "anim") {
    # animation diagnostics: player 1 is driven through the same code path as player 2,
    # so anim_dump.txt shows both pawns moving at the same time
    Say "anim test: forward for 8 s, player 1 driven too"
    Set-Test "0,1,0,0,0,0,1"
    Start-Sleep -Seconds 3
    Shot "anim-a"
    Start-Sleep -Seconds 3
    Shot "anim-b"
    Set-Test "0,0"
    Start-Sleep -Seconds 2
} elseif ($Mode -eq "pose") {
    # walk animation check: the character walks a short distance so it stays inside the
    # fixed camera; anim_dump.txt has foot/hand bone positions for every sampled second
    Say "pose test: idle, then an uninterrupted walk (screenshots pause the game)"
    Start-Sleep -Seconds 6
    Set-Test "0,0"
    Start-Sleep -Milliseconds 1500
    Shot "pose-idle"
    Say "walk backwards (away from the ledge) - no screenshots, so the game keeps running"
    Set-Test "0,-1"
    Start-Sleep -Seconds 5
    Say "walk forwards"
    Set-Test "0,1"
    Start-Sleep -Milliseconds 1500
    Set-Test "0,0"
    Start-Sleep -Milliseconds 1000
    Shot "pose-final"
    Start-Sleep -Milliseconds 300
} elseif ($Mode -eq "pad1") {
    # walk player 1 with the keyboard: gives a reference for what a really walking pawn
    # puts into its animation blueprint
    Say "player 1 walk test: holding W for 6 s"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $winPs1 -Action hold -Keys W -Seconds 6 | Out-Null
    Start-Sleep -Seconds 2
    Say "player 1 stop"
} elseif ($Mode -eq "pose2") {
    # freeze the game mid-walk and compare two frozen frames: if the pose changes, the
    # walk cycle is playing; if the frames are identical, the mesh is a frozen statue
    Say "pose2 test: paused frames of a walking player 2"
    Start-Sleep -Seconds 6
    Set-Test "0,1,0,0,0,0,0,0"
    Start-Sleep -Milliseconds 1200
    Set-Test "0,1,0,0,0,0,0,1"
    Start-Sleep -Milliseconds 500
    Shot "poseA"
    Set-Test "0,1,0,0,0,0,0,0"
    Start-Sleep -Milliseconds 180
    Set-Test "0,1,0,0,0,0,0,1"
    Start-Sleep -Milliseconds 500
    Shot "poseB"
    Set-Test "0,0,0,0,0,0,0,1"
    Start-Sleep -Milliseconds 400
    Shot "poseC"
    Set-Test "0,0,0,0,0,0,0,0"
    Start-Sleep -Milliseconds 400
} elseif ($Mode -eq "pose3") {
    # walk on the spot (direction reversed every bridge tick) and freeze three frames:
    # same position, same facing, so any difference between the frames is the pose itself
    Say "pose3 test: paused frames of player 2 walking on the spot"
    Start-Sleep -Seconds 6
    Set-Test "0,1,0,0,0,0,0,0,1"
    Start-Sleep -Milliseconds 1500
    Set-Test "0,1,0,0,0,0,0,1,1"
    Start-Sleep -Milliseconds 500
    Shot "jitA"
    Set-Test "0,1,0,0,0,0,0,0,1"
    Start-Sleep -Milliseconds 200
    Set-Test "0,1,0,0,0,0,0,1,1"
    Start-Sleep -Milliseconds 500
    Shot "jitB"
    Set-Test "0,1,0,0,0,0,0,0,1"
    Start-Sleep -Milliseconds 230
    Set-Test "0,1,0,0,0,0,0,1,1"
    Start-Sleep -Milliseconds 500
    Shot "jitC"
    Set-Test "0,0,0,0,0,0,0,1,0"
    Start-Sleep -Milliseconds 400
    Shot "jitStop"
    Set-Test "0,0,0,0,0,0,0,0,0"
    Start-Sleep -Milliseconds 400
} elseif ($Mode -eq "pose4") {
    # three frozen frames of a pawn walking on the spot: baseline, with Acceleration
    # written as well, and after rebuilding the anim instance
    Say "pose4 test: jitter baseline / acceleration / anim reinit"
    Start-Sleep -Seconds 6
    Set-Test "0,1,0,0,0,0,0,0,1,0,0"
    Start-Sleep -Milliseconds 1500
    Set-Test "0,1,0,0,0,0,0,1,1,0,0"
    Start-Sleep -Milliseconds 500
    Shot "jitBase"
    Set-Test "0,1,0,0,0,0,0,0,1,1,0"
    Start-Sleep -Milliseconds 600
    Set-Test "0,1,0,0,0,0,0,1,1,1,0"
    Start-Sleep -Milliseconds 500
    Shot "jitAcc"
    Set-Test "0,1,0,0,0,0,0,0,1,0,1"
    Start-Sleep -Milliseconds 800
    Set-Test "0,1,0,0,0,0,0,1,1,0,1"
    Start-Sleep -Milliseconds 500
    Shot "jitReinit"
    Set-Test "0,0,0,0,0,0,0,1,0,0,1"
    Start-Sleep -Milliseconds 400
    Shot "jitReinitStop"
    Set-Test "0,0,0,0,0,0,0,0,0,0,0"
    Start-Sleep -Milliseconds 400
} elseif ($Mode -eq "pose5") {
    # zoom player 2's camera and freeze three frames of a walk on the spot
    Say "pose5 test: zoomed p2 camera, three frozen walk frames"
    Start-Sleep -Seconds 6
    Set-Test "0,1,0,0,0,0,0,0,1,0,0,20"
    Start-Sleep -Milliseconds 1500
    Set-Test "0,1,0,0,0,0,0,1,1,0,0,20"
    Start-Sleep -Milliseconds 500
    Shot "zoomA"
    Set-Test "0,1,0,0,0,0,0,0,1,0,0,20"
    Start-Sleep -Milliseconds 160
    Set-Test "0,1,0,0,0,0,0,1,1,0,0,20"
    Start-Sleep -Milliseconds 500
    Shot "zoomB"
    Set-Test "0,1,0,0,0,0,0,0,1,0,0,20"
    Start-Sleep -Milliseconds 190
    Set-Test "0,1,0,0,0,0,0,1,1,0,0,20"
    Start-Sleep -Milliseconds 500
    Shot "zoomC"
    Set-Test "0,0,0,0,0,0,0,1,0,0,0,20"
    Start-Sleep -Milliseconds 500
    Shot "zoomStop"
    Set-Test "0,0,0,0,0,0,0,0,0,0,0,0"
    Start-Sleep -Milliseconds 400
} elseif ($Mode -eq "pose6") {
    # scale player 2's mesh up and freeze three walk frames: the pose is big enough to see
    Say "pose6 test: scaled-up p2, three frozen walk frames"
    Start-Sleep -Seconds 6
    Set-Test "0,1,0,0,0,0,0,0,1,0,0,0,3"
    Start-Sleep -Milliseconds 1500
    Set-Test "0,1,0,0,0,0,0,1,1,0,0,0,3"
    Start-Sleep -Milliseconds 500
    Shot "sclA"
    Set-Test "0,1,0,0,0,0,0,0,1,0,0,0,3"
    Start-Sleep -Milliseconds 170
    Set-Test "0,1,0,0,0,0,0,1,1,0,0,0,3"
    Start-Sleep -Milliseconds 500
    Shot "sclB"
    Set-Test "0,1,0,0,0,0,0,0,1,0,0,0,3"
    Start-Sleep -Milliseconds 210
    Set-Test "0,1,0,0,0,0,0,1,1,0,0,0,3"
    Start-Sleep -Milliseconds 500
    Shot "sclC"
    Set-Test "0,0,0,0,0,0,0,1,0,0,0,0,3"
    Start-Sleep -Milliseconds 500
    Shot "sclStop"
    Set-Test "0,0,0,0,0,0,0,0,0,0,0,0,0"
    Start-Sleep -Milliseconds 400
} elseif ($Mode -eq "pickup") {
    # player 2 pickup: RT (AxisGrab) with a long test radius, walk with the item,
    # then RT again to put it down. The mesh is scaled up so the item is visible.
    Say "pickup test: RT to pick up the nearest carryable (test radius 2000)"
    Start-Sleep -Seconds 6
    # release first: the bridge's grab state may still be "pressed" from the real pad
    Set-Test "0,0,0,0,0,0,0,0,0,0,0,0,3,0,2000"
    Start-Sleep -Seconds 2
    Set-Test "0,0,0,0,0,0,0,0,0,0,0,0,3,1,2000"
    Start-Sleep -Seconds 8
    Set-Test "0,0,0,0,0,0,0,0,0,0,0,0,3,0,2000"
    Start-Sleep -Seconds 3
    Shot "pickup-held"
    Say "pickup test: walk backwards while carrying"
    Set-Test "0,-1,0,0,0,0,0,0,0,0,0,0,3,0,2000"
    Start-Sleep -Seconds 2
    Set-Test "0,0,0,0,0,0,0,0,0,0,0,0,3,0,2000"
    Start-Sleep -Seconds 1
    Shot "pickup-walk"
    Say "pickup test: RT again to put the item down"
    Set-Test "0,0,0,0,0,0,0,0,0,0,0,0,3,0,2000"
    Start-Sleep -Seconds 1
    Set-Test "0,0,0,0,0,0,0,0,0,0,0,0,3,1,2000"
    Start-Sleep -Seconds 2
    Set-Test "0,0,0,0,0,0,0,0,0,0,0,0,3,0,2000"
    Start-Sleep -Seconds 4
    Shot "pickup-putdown"
    Set-Test "0,0,0,0,0,0,0,0,0,0,0,0,0,0,0"
    Start-Sleep -Milliseconds 500
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
# the console was minimised so the game could keep the focus; bring it back while the
# game window still exists (win.ps1 exits early when it cannot find it)
& powershell -NoProfile -ExecutionPolicy Bypass -File $winPs1 -Action restore | Out-Null
Get-Process -Name $exeName -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

if (Test-Path $log) {
    Copy-Item $log (Join-Path $OutDir "bridge-test.log") -Force
    Say "log copied to $(Join-Path $OutDir 'bridge-test.log')"
}

# put the user's own save and settings back before anything else
Restore-UserSave

if (Test-Path $log) {
    Say "----- interesting log lines -----"
    Select-String -Path $log -Pattern "world ->|create player|player 2 placed|stepped aside|ClientRestart|input bridge|bridge state|test drive|switching to direct|jump|p2 state" |
        ForEach-Object { $_.Line } | Select-Object -Last 80
} else {
    Say "no log was written"
}
