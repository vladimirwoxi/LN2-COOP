# LN2 COOP installer: puts the mod into an installed Little Nightmares II and makes
# sure the bundled UE4SS is the patched build this game needs.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File install.ps1 -GameDir "G:\Little Nightmares 2"
#   powershell -ExecutionPolicy Bypass -File install.ps1 -GameDir "G:\Little Nightmares 2" -DryRun
#
# What it does:
#   1. checks that dwmapi.dll + ue4ss\UE4SS.dll are present (unpack the release first)
#   2. verifies UE4SS.dll; if it is the untouched original, applies the ProcessEvent patch
#      (tools\patch_ue4ss.ps1), keeping UE4SS.dll.orig
#   3. fixes the UE4SS-settings.ini keys this game needs
#   4. copies mod\ into ue4ss\Mods\LN2Coop (keeps an existing coop.cfg)
#   5. enables LN2Coop in ue4ss\Mods\mods.txt
#
# The script is idempotent: run it again after a game/UE4SS update or when moving the mod.

param(
    [Parameter(Mandatory = $true)][string]$GameDir,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$UE4SS_ORIG_SHA    = "CE5E3C46A920CC00B2817AC61E438C9162830290379D0B5B9C4DFC2B29459290"
$UE4SS_PATCHED_SHA = "A5757099377921CFC8D51032E3D8E29B8D29B76D728F88C990C33BC45FA00A33"
$GAME_EXE_SHA      = "468DEF5F335F1984855818CFF8BBE0F2B2CD6D36AA0C57ACDE32A1D92E3F05F2"

$REQUIRED_INI = [ordered]@{
    "bUseUObjectArrayCache"            = "false"
    "DefaultExecuteInGameThreadMethod" = "EngineTick"
    "DefaultFNameToStringMethod"       = "Scan"
    "ConsoleEnabled"                   = "0"
    "GuiConsoleEnabled"                = "0"
    "GuiConsoleVisible"                = "0"
    "GuiConsoleFontScaling"            = "1"
    "MaxMemoryUsageDuringAssetLoading" = "80"
    "HookInitGameState"                = "0"
    "HookProcessConsoleExec"           = "0"
}

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Note($msg) { Write-Host "    $msg" }
function Action($msg) {
    if ($DryRun) { Write-Host "    [dry-run] $msg" -ForegroundColor Yellow }
    else { Write-Host "    $msg" }
}

# ------------------------------------------------------------------ locations
$bin = Join-Path $GameDir "Helios\Binaries\Win64"
if (-not (Test-Path $bin)) {
    throw "Not a Little Nightmares II folder: '$GameDir' (expected Helios\Binaries\Win64)."
}
$exe = Join-Path $bin "Little_Nightmares_II_Enhanced-Win64-Shipping.exe"
$ue4ssDir = Join-Path $bin "ue4ss"
$dll = Join-Path $ue4ssDir "UE4SS.dll"
$ini = Join-Path $ue4ssDir "UE4SS-settings.ini"
$proxy = Join-Path $bin "dwmapi.dll"
$modSrc = Join-Path $PSScriptRoot "..\mod"
$modDst = Join-Path $ue4ssDir "Mods\LN2Coop"
$modsTxt = Join-Path $ue4ssDir "Mods\mods.txt"

Step "Target: $bin"

# --------------------------------------------------------------- 0. sanity
if (-not (Test-Path $exe)) { throw "Game exe not found: $exe" }
$gameSha = (Get-FileHash $exe -Algorithm SHA256).Hash
if ($gameSha -ne $GAME_EXE_SHA) {
    Write-Warning "Game build differs from the tested one."
    Write-Warning "  found : $gameSha"
    Write-Warning "  tested: $GAME_EXE_SHA"
    Write-Warning "The UE4SS patch offsets are build specific - verify in game before playing."
}

# ------------------------------------------------------- 1. UE4SS is present
if (-not (Test-Path $proxy) -or -not (Test-Path $dll)) {
    throw @"
UE4SS is not installed in this game folder (missing dwmapi.dll and/or ue4ss\UE4SS.dll).

Download ue4ss-patched.zip from the LN2-COOP releases page and extract it into:
  $bin

Then run this script again. To fetch it with the GitHub CLI:
  gh release download v0.3 -R vladimirwoxi/LN2-COOP -p ue4ss-patched.zip -D .
  Expand-Archive ue4ss-patched.zip -DestinationPath "$bin" -Force
"@
}
Step "UE4SS runtime present"

# ---------------------------------------------------- 2. UE4SS.dll is patched
$sha = (Get-FileHash $dll -Algorithm SHA256).Hash
if ($sha -eq $UE4SS_PATCHED_SHA) {
    Step "UE4SS.dll is already patched"
} elseif ($sha -eq $UE4SS_ORIG_SHA) {
    Step "UE4SS.dll is untouched - applying the ProcessEvent patch"
    if ($DryRun) {
        Action "would run tools\patch_ue4ss.ps1 -Dll `"$dll`""
    } else {
        & (Join-Path $PSScriptRoot "patch_ue4ss.ps1") -Dll $dll -GameExe $exe
        $sha = (Get-FileHash $dll -Algorithm SHA256).Hash
        if ($sha -ne $UE4SS_PATCHED_SHA) { throw "Patch failed: unexpected hash $sha" }
    }
} else {
    throw @"
Unknown UE4SS.dll build, refusing to patch it.
  found : $sha
  wanted: $UE4SS_ORIG_SHA (then patched to $UE4SS_PATCHED_SHA)
Replace it with the UE4SS.dll from ue4ss-patched.zip and run this script again.
"@
}

# ------------------------------------------------ 3. UE4SS-settings.ini keys
Step "Checking UE4SS-settings.ini"
if (-not (Test-Path $ini)) {
    Write-Warning "  missing $ini - UE4SS will use its defaults; co-op will probably crash on level load."
} else {
    $text = [System.IO.File]::ReadAllText($ini)
    $changed = @()
    foreach ($k in $REQUIRED_INI.Keys) {
        $want = $REQUIRED_INI[$k]
        $rx = "(?m)^\s*" + [regex]::Escape($k) + "\s*=\s*([^\r\n#;]*)"
        $m = [regex]::Match($text, $rx)
        if (-not $m.Success) {
            $text = $text.TrimEnd() + "`r`n$k = $want`r`n"
            $changed += "$k -> $want (added)"
        } elseif ($m.Groups[1].Value.Trim() -ne $want) {
            $text = [regex]::Replace($text, $rx, "$k = $want", 1)
            $changed += "$k : $($m.Groups[1].Value.Trim()) -> $want"
        }
    }
    if ($changed.Count -eq 0) {
        Note "all required keys are correct"
    } else {
        foreach ($c in $changed) { Action "ini: $c" }
        if (-not $DryRun) {
            $backup = "$ini.ln2coop.bak"
            if (-not (Test-Path $backup)) { Copy-Item $ini $backup }
            [System.IO.File]::WriteAllText($ini, $text, (New-Object System.Text.UTF8Encoding($false)))
        }
    }
}

# ------------------------------------------------------------------ 4. the mod
Step "Installing the mod into $modDst"
if (-not (Test-Path (Join-Path $modSrc "Scripts\main.lua"))) {
    throw "Mod sources not found: $modSrc (run the script from the repository)"
}
$files = @(
    @{ from = "Scripts\main.lua";  to = "Scripts\main.lua";  keep = $false },
    @{ from = "README.txt";        to = "README.txt";        keep = $false },
    @{ from = "coop.cfg";          to = "coop.cfg";          keep = $true  }
)
foreach ($f in $files) {
    $src = Join-Path $modSrc $f.from
    $dst = Join-Path $modDst $f.to
    if ($f.keep -and (Test-Path $dst)) { Note "kept existing $($f.to)"; continue }
    Action "copy $($f.from)"
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
        Copy-Item $src $dst -Force
    }
}
Action "copy patch_ue4ss.ps1 (so the patch can be re-applied from the game folder)"
if (-not $DryRun) {
    Copy-Item (Join-Path $PSScriptRoot "patch_ue4ss.ps1") (Join-Path $modDst "patch_ue4ss.ps1") -Force
}

# --------------------------------------------------------------- 5. mods.txt
Step "Enabling LN2Coop in Mods\mods.txt"
$line = "LN2Coop : 1"
$content = ""
if (Test-Path $modsTxt) { $content = [System.IO.File]::ReadAllText($modsTxt) }
$lines = @($content -split "`r?`n" | Where-Object { $_.Trim() -ne "" })
$current = @($lines | Where-Object { $_ -match '^\s*LN2Coop\s*:' })
if ($current.Count -gt 0 -and $current[0].Trim() -eq $line) {
    Note "already enabled"
} else {
    $lines = @($lines | Where-Object { $_ -notmatch '^\s*LN2Coop\s*:' }) + $line
    Action "mods.txt: $line"
    if (-not $DryRun) {
        [System.IO.File]::WriteAllText($modsTxt, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    }
}

# ----------------------------------------------------------------- summary
Write-Host ""
if ($DryRun) {
    Write-Host "Dry run finished - nothing was changed." -ForegroundColor Yellow
} else {
    Write-Host "Installed." -ForegroundColor Green
}
Write-Host @"
Play:
  1. connect TWO gamepads before launching the game
  2. start Little Nightmares II normally and press Continue
  3. a level loads -> the second Mono appears and the screen splits

Co-op can be switched off in
  $modDst\coop.cfg        (on / off)
Mod log:
  $modDst\LN2Coop.log
"@
