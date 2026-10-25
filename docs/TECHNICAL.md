# TECHNICAL — как это работает и что было сломано

Всё ниже проверено на реальной игре (не по документации).

## Идентификация сборки

| Объект | Значение |
|---|---|
| Игра | Little Nightmares II Enhanced Edition (GOG) |
| UE | 4.26, проект `Helios` |
| exe | `Little_Nightmares_II_Enhanced-Win64-Shipping.exe`, SHA-256 `468DEF5F335F1984855818CFF8BBE0F2B2CD6D36AA0C57ACDE32A1D92E3F05F2` |
| UE4SS | experimental `v3.0.1-1181-g83330635`, proxy `dwmapi.dll` |
| `UE4SS.dll` оригинал | SHA-256 `CE5E3C46A920CC00B2817AC61E438C9162830290379D0B5B9C4DFC2B29459290` |
| `UE4SS.dll` пропатченный | SHA-256 `A5757099377921CFC8D51032E3D8E29B8D29B76D728F88C990C33BC45FA00A33` |

## Проблема №1: ProcessEvent

### Симптомы

Любой вызов UFunction из Lua возвращал «ноль», без ошибок:

```lua
Add_IntInt(2, 3)                      --> 0        (должно быть 5)
K2_GetActorLocation()                 --> (0,0,0)
GameplayStatics:CreatePlayer(...)     --> nil      --> второй игрок не создаётся
```

`Print`/`Log` работали, объекты находились (`StaticFindObject`, `FindAllOf`) — то есть UObject-слой жив, а именно вызов функций шёл в пустоту.

### Причина

1. UE4SS ищет `UObject::ProcessEvent` сканированием; на этой сборке RVA `0xA0C0A0` указывает на **пустую заглушку**:

```
xor eax, eax
ret
```

2. UE4SS вызывает функции через `RC::Unreal::UObject::ProcessEvent` (в `UE4SS.dll`, RVA `0x3ECCC0` по PDB-символам), а тот диспетчеризуется через слот `0x218` vtable объекта (глобал в `UE4SS.dll` по RVA `0x134C98C`, значение `0x218`).

3. Слот `0x218` в vtable **каждого** класса игры тоже указывает на ту же заглушку → вызов уходит в `xor eax,eax; ret` → «ноль» и никаких исключений.

4. Настоящий `UObject::ProcessEvent` — **не виртуальная** функция в exe игры: RVA `0x2875080`. Она начинается с проверки `FunctionFlags & FUNC_Native (0x400)` и дальше либо зовёт нативную `Func`, либо интерпретирует байткод.

### Решение

Бинарный патч `UE4SS.dll`: тело `RC::Unreal::UObject::ProcessEvent` (RVA `0x3ECCC0`) заменяется 21-байтным переходом к настоящей функции игры.

```asm
65 48 8B 04 25 60 00 00 00   mov rax, gs:[0x60]     ; PEB текущего процесса
48 8B 40 10                  mov rax, [rax+0x10]    ; PEB->ImageBaseAddress
48 05 80 50 87 02            add rax, 0x2875080     ; RVA UObject::ProcessEvent
FF E0                        jmp rax
```

- **ASLR-безопасно**: адрес считается от базы главного модуля, а не хардкодится.
- **Аргументы сохраняются**: `jmp` (не `call`), `rax` — скрэтч-регистр в x64-соглашении, все аргументы в `rcx/rdx/r8/r9` и на стеке передаются как есть; вызывающий ждёт `ret`-семантику, которую обеспечивает сама целевая функция.
- **Игра не патчится**, меняется только слой UE4SS, который и так был обязан вызвать `ProcessEvent`.

Патч накладывает [`tools/patch_ue4ss.ps1`](../tools/patch_ue4ss.ps1): проверяет SHA-256 exe игры и самого DLL, маппит RVA → файловый offset по таблице секций PE, делает бэкап `UE4SS.dll.orig`, пишет байты. Идемпотентен (`Already patched - nothing to do`), отказывается патчить неизвестную сборку.

### После патча (проверено)

```
Add_IntInt(2, 3)  -> 5
CreatePlayer(pc, 1, true) -> второй ULocalPlayer, дальше игра сама спавнит Pawn+Controller
```

### Что НЕ сработало (не повторять)

| Попытка | Результат |
|---|---|
| Override сигнатуры `ProcessEvent` через AOB (как для других функций) | Невозможно: UE4SS помечает ProcessEvent как неоверрайдибельный (`fixing-compatibility-problems.md`) |
| Патч заглушки `0xA0C0A0` (сама игра её использует) | Процесс умирает |
| Смена vtable-слота `0x218` → `0x748` и правка слота 1 в UObject vtable | Не помогло: диспетчеризация идёт через `0x218`, но вызов приходит из обёртки UE4SS — патчить надо было её |
| UE4SS 3.0.1 stable | Падение на старте (нет event loop) |

## Проверенные структуры (для будущих сессий)

`UFunction` в этой сборке:

| Смещение | Поле |
|---|---|
| `0xB0` | `FunctionFlags` |
| `0xB4` | `NumParms` (u8) |
| `0xB6` | `ParmsSize` (u16) |
| `0xB8` | `ReturnValueOffset` (u16) |
| `0xD8` | `Func` (указатель на нативную реализацию) |

`FUNC_Native = 0x400`.

`UObject::ProcessEvent` (exe RVA `0x2875080`): `if (FunctionFlags & FUNC_Native) { ((NativeFunc)Func)(this, parms, retval); return; }` иначе — выполнение байткода.

## Мод: как создаётся второй игрок

```
upkeep() каждые 2 с (ExecuteInGameThread)
  └─ world name содержит "PLVL_" (игровой уровень)?
       ├─ нет  → bUseSplitscreen = false (меню не делим), выход
       └─ да   → bUseSplitscreen = true
                 localPlayerCount < 2 ?
                   └─ GameplayStatics:CreatePlayer(pc1, ControllerId=1, bSpawnPlayerController=true)
                        └─ UGameInstance::CreateLocalPlayer → второй ULocalPlayer
                             └─ игра сама: BP_PlayerPawnController_C + BP_PlayerPawn_C + камера
                 P2 pawn = BP_PlayerPawn_C ?
                   ├─ ещё нет → вернуться на следующем тике (респавн на чекпоинте)
                   └─ да → log input/controller; один раз на мир:
                           K2_SetActorLocationAndRotation(позиция P1 + right*130, rot P1, false, {}, true)
```

Почему `bUseSplitscreen`: без него движок оставляет обоим игрокам один вьюпорт (второй игрок «невидим»). Почему не трогаем Шестую: она живёт в `BP_SixPawn_C` под `BP_PlaypalAIController_C`, и её поведение привязано к сюжету; второй игрок должен быть полным Моно.

Конфиг мода: `pad2 = 1`, `spawnSideOffset = 130.0`, `interval = 2000` мс (см. `mod/Scripts/main.lua`).

## Важные классы и миры

| Имя | Что |
|---|---|
| `BP_PlayerPawn_C` | Моно (игрок 1 и, после мода, игрок 2) |
| `BP_PlayerPawnController_C` | контроллер игрока |
| `BP_IngameGameMode_C` | GameMode уровня |
| `BP_SixPawn_C` / `BP_PlaypalAIController_C` | Шестая / её AI |
| `HeliosGameViewportClient` | вьюпорт (разделение экрана, letterbox 16:9 на половину) |
| `HeliosGameInstanceBP_C` | GameInstance (`LocalPlayers`) |
| `HeliosPlayerInput` | PlayerInput |
| `BootupMenu` → `LVL_MainMenu` → `PLVL_Wilderness` | стартовая цепочка загрузки |

## Настройки UE4SS, без которых не работает

`ue4ss/UE4SS-settings.ini`:

```ini
HookInitGameState = 0
HookProcessConsoleExec = 0
bUseUObjectArrayCache = false
DefaultExecuteInGameThreadMethod = EngineTick
DefaultFNameToStringMethod = Scan
ConsoleEnabled = 0
GuiConsoleEnabled = 0
GuiConsoleVisible = 0
MaxMemoryUsageDuringAssetLoading = 80
```

`HookInitGameState = 1` / `HookProcessConsoleExec = 1` → краш на старте уровня.

## Инструменты, которыми это искалось

- Python 3.12 + `capstone` 5.0.7 (дизассемблирование exe), `Pillow` (скриншоты).
- `Add-Type` + `ReadProcessMemory`/`WriteProcessMemory` из PowerShell — чтение памяти живой игры, патчинг на лету.
- DbgHelp через P/Invoke из PowerShell — чтение `UE4SS.pdb` (так найден RVA `0x3ECCC0` для `RC::Unreal::UObject::ProcessEvent`).
- `G:\LN2\local\win.ps1` — фокус окна, нажатия клавиш, скриншоты (игра на паузе без фокуса).
- Компилятора нет (MSVC без заголовков/импорт-библиотек, MinGW не ставился) — поэтому всё на Lua + PowerShell + бинарный патч.
