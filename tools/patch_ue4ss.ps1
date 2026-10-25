# Re-applies the LN2Coop UE4SS patch to UE4SS.dll.
#
# Why: on this game build UE4SS's ProcessEvent scan lands on an empty stub
# (xor eax,eax; ret). Every Lua UFunction call then silently returns zero and
# UGameplayStatics::CreatePlayer cannot add a second local player.
#
# The patch replaces the body of RC::Unreal::UObject::ProcessEvent (RVA 0x3ECCC0)
# with:
#     mov rax, gs:[0x60]      ; PEB
#     mov rax, [rax+0x10]     ; PEB->ImageBaseAddress (the game exe)
#     add rax, 0x2875080      ; RVA of UObject::ProcessEvent in the game
#     jmp rax
# which is ASLR safe and preserves the original arguments.
#
# Usage (PowerShell):
#   powershell -ExecutionPolicy Bypass -File patch_ue4ss.ps1
#   powershell -ExecutionPolicy Bypass -File patch_ue4ss.ps1 -Dll "D:\game\...\UE4SS.dll"

param(
    [string]$Dll = (Join-Path $PSScriptRoot "..\..\UE4SS.dll"),
    [string]$GameExe = ""
)

$ErrorActionPreference = "Stop"

$UE4SS_ORIG_SHA = "CE5E3C46A920CC00B2817AC61E438C9162830290379D0B5B9C4DFC2B29459290"
$UE4SS_PATCHED_SHA = "A5757099377921CFC8D51032E3D8E29B8D29B76D728F88C990C33BC45FA00A33"
$GAME_EXE_SHA = "468DEF5F335F1984855818CFF8BBE0F2B2CD6D36AA0C57ACDE32A1D92E3F05F2"
$WRAPPER_RVA = 0x3ECCC0
$PROCESS_EVENT_RVA = 0x02875080

if (-not (Test-Path $Dll)) { throw "UE4SS.dll not found: $Dll" }
if (-not $GameExe) { $GameExe = Join-Path (Split-Path (Split-Path $Dll)) "Little_Nightmares_II_Enhanced-Win64-Shipping.exe" }
if (-not (Test-Path $GameExe)) { throw "Game exe not found: $GameExe (pass -GameExe)" }

$gameHash = (Get-FileHash $GameExe -Algorithm SHA256).Hash
if ($gameHash -ne $GAME_EXE_SHA) {
    throw "Unexpected game build ($gameHash). This patch is for $GAME_EXE_SHA; patch offsets would be wrong."
}

$hash = (Get-FileHash $Dll -Algorithm SHA256).Hash
Write-Host "UE4SS.dll : $hash"
if ($hash -eq $UE4SS_PATCHED_SHA) { Write-Host "Already patched - nothing to do."; exit 0 }
if ($hash -ne $UE4SS_ORIG_SHA) {
    throw "Unexpected UE4SS.dll (expected $UE4SS_ORIG_SHA). Refusing to patch an unknown build."
}

# read PE section table and map the RVA to a file offset
$bytes = [System.IO.File]::ReadAllBytes($Dll)
$pe = [BitConverter]::ToInt32($bytes, 0x3C)
$nsec = [BitConverter]::ToUInt16($bytes, $pe + 6)
$optSize = [BitConverter]::ToUInt16($bytes, $pe + 20)
$opt = $pe + 24
$magic = [BitConverter]::ToUInt16($bytes, $opt)
$secTable = $opt + $(if ($magic -eq 0x20B) { 240 } else { 224 })

$fileOffset = -1
for ($i = 0; $i -lt $nsec; $i++) {
    $o = $secTable + $i * 40
    $va = [BitConverter]::ToUInt32($bytes, $o + 12)
    $vsz = [BitConverter]::ToUInt32($bytes, $o + 8)
    $rawSize = [BitConverter]::ToUInt32($bytes, $o + 16)
    $rawPtr = [BitConverter]::ToUInt32($bytes, $o + 20)
    $span = [Math]::Max($vsz, $rawSize)
    if ($WRAPPER_RVA -ge $va -and $WRAPPER_RVA -lt ($va + $span)) {
        $fileOffset = $rawPtr + ($WRAPPER_RVA - $va)
        break
    }
}
if ($fileOffset -lt 0) { throw "Could not map RVA 0x$($WRAPPER_RVA.ToString('X'))" }

# mov rax, gs:[0x60]; mov rax, [rax+0x10]; add rax, imm32; jmp rax
$stub = [byte[]](0x65,0x48,0x8B,0x04,0x25,0x60,0x00,0x00,0x00,
                 0x48,0x8B,0x40,0x10,
                 0x48,0x05) + [BitConverter]::GetBytes([uint32]$PROCESS_EVENT_RVA) + [byte[]](0xFF,0xE0)

$backup = "$Dll.orig"
if (-not (Test-Path $backup)) { Copy-Item $Dll $backup; Write-Host "backup    : $backup" }

[System.IO.File]::WriteAllBytes($Dll, $bytes)  # ensure writable, then edit in place
$bytes = [System.IO.File]::ReadAllBytes($Dll)
[Array]::Copy($stub, 0, $bytes, $fileOffset, $stub.Length)
[System.IO.File]::WriteAllBytes($Dll, $bytes)

$newHash = (Get-FileHash $Dll -Algorithm SHA256).Hash
Write-Host "patched   : $Dll"
Write-Host "new hash  : $newHash"
if ($newHash -ne $UE4SS_PATCHED_SHA) { Write-Warning "Hash differs from the tested patched build - verify in game." }
