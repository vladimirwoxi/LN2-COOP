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

## Мод v0.6: создание и ведение второго игрока

### Создание

```
upkeep() каждые 1 с (ExecuteInGameThread)
  └─ world name содержит "PLVL_"?
       ├─ нет  → bUseSplitscreen = false (меню не делим), P2 = nil, выход
       └─ да   → bUseSplitscreen = true
                 localPlayerCount < 2 ?
                   └─ GameplayStatics:CreatePlayer(pc1, ControllerId=1, spawn=true)
                        └─ игра сама: BP_PlayerPawnController_C + BP_PlayerPawn_C + камера
                 P2 pawn = BP_PlayerPawn_C ?
                   ├─ новый pawn → placePlayer2()
                   └─ уже стоит  → keepPlayer2Near()
```

`placePlayer2`:

1. `K2_SetActorLocationAndRotation(p1.location, p1.rotation, bSweep=false, ..., bTeleport=true)` —
   ровно в точку p1.
2. `mv:StopMovementImmediately()` — телепорт сохраняет старую скорость (иначе падение
   продолжается с новой точки).
3. `mv:SetMovementMode(MOVE_Walking, 0)` — выйти из `MOVE_Falling`.
4. `SetCollisionResponseToChannel(ECC_Pawn=2, ECR_Ignore=0)` на капсуле p2 — иначе два
   Моно блокируют друг друга в одной точке.

Почему ровно в p1: у уровня нет PlayerStart для второго игрока, спавн оказывается вне
меша пола (Z до −3400), пешка падает, камера уходит под карту → нижняя половина чёрная.
Точка p1 гарантированно на полу. Смещение в сторону (45–80 см) небезопасно: свип упирается
в камень, пешка зажимается, и дальше не идёт ни в одну сторону.

### Мост ввода

`LoopAsync(33ms)` → `ExecuteInGameThread`:

```
readSticks(pc2)  -- GetInputAnalogKeyState(Gamepad_*) или bridge_test.txt
  ├─ левый стик → dir относительно pc2:GetControlRotation()
  │    └─ mv.Velocity = dir * 210 (с компенсацией торможения)
  ├─ правый стик → pc2:SetControlRotation(Pitch, Yaw + rx*150*dt)
  ├─ A (edge) → pawn:Jump(); если через 0.12 с Z-скорость < 50:
  │                SetMovementMode(MOVE_Falling); Velocity.Z = 420
  └─ раз в 1 с → строка "p2 state: ..." в лог
```

Почему `mv.Velocity`, а не `AddMovementInput`:

- `pc2:IsMoveInputIgnored()` = `false`, `pawn:IsMoveInputIgnored()` = `false`.
- `pawn:AddMovementInput(dir, 1, true)` не даёт смещения (0 единиц за 0.5 с).
- `AddActorWorldOffset` со свипом тоже не двигает, когда пешка стоит в точке p1
  (перекрытие/геометрия).
- Прямая запись `mv.Velocity` двигает: коллизии, склоны, гравитация и анимация работают,
  потому что движение выполняет сам `CharacterMovementComponent`.

Скорость: между тиками моста компонент тормозит (входного вектора нет), поэтому фактическая
скорость ниже записанной. Мост оценивает проекцию текущей скорости на желаемое направление
и пишет `speed + (speed - along)` (не больше 1.5×). В логе на склоне 130–176 ед/с, на ровном
ближе к 210.

### Камера

`SetControlRotation` (не `AddControllerYawInput`): `GetControlRotation()` → добавить
`rx * 150°/s * dt`, pitch `ry * 150°/s * dt * 0.7`, кламп ±80°. Проверено: yaw 160° → 303°
за ~2.4 с, вид нижней половины меняется. Камера p2 следует за своей пешкой (`ClientRestart`
обновляет view target).

### Прыжок

`Character::Jump()` возвращает `ok`, но не поднимает пешку (`vz` остаётся 0): игра, видимо,
игнорирует jump-ввод p2. Работает принудительный путь:

```lua
mv:SetMovementMode(3 /*MOVE_Falling*/, 0)
mv.Velocity = { X = v.X, Y = v.Y, Z = 420 }
```

Проверено: z 634 → 679 → 634, `mode=3` в полёте. Высота ~45 см соответствует
`GravityScale` игры.

### Тестовый режим

`bridge_test.txt` в папке мода: `x,y` или `x,y,rx,ry,jump` (значения −1…1). Пока файл есть,
мост берёт стики оттуда (`test=true` в логе); удалить файл — снова реальный пад.
`tools/test_bridge.ps1` раскладывает мод в `G:\LN2\test-install`, проходит в
`PLVL_Wilderness` и гоняет сценарий (auto/quick/pad).

## Ввод второго игрока: почему штатный путь не работает

Проверено на тестовой копии (сессии 5–6):

| Факт | Как проверено |
|---|---|
| Пад 2 доходит до PlayerInput контроллера p2 | `pc2:IsInputKeyDown` → true; `pc2:GetInputAnalogKeyState` → −1.00…1.00 именно от второго пада |
| Игра не выполняет действия для p2 | при нажатиях на паде 2 пешка p1 идёт (210), пешка p2 стоит |
| `AddMovementInput` не даёт ускорения | `IsMoveInputIgnored()=false`, `pawn:IsMoveInputIgnored()=false`, но 0 единиц за 0.5 с; с `bForce=true` то же |
| `ClientRestart`/`Possess` не помогают | вызовы проходят без ошибок, ввода не возвращают |
| `PushInputComponent` из Lua недоступен | TrivialObject |
| `bOffsetPlayerGamepadIds = true` ломает p1 | проверено в игре, откатили на false |
| `MoveIgnoreActorAdd` не вызывается | TrivialObject/без эффекта; работает `SetCollisionResponseToChannel` |
| Второй pawn спавнится вне уровня | Z до −3400, падение |
| Постановка точно в p1 приземляет p2 | Z 596, скорость 0, нижняя половина рисуется |
| `mv.Velocity` двигает p2 | скорость 130–176, позиция меняется на сотни единиц |
| `SetControlRotation` крутит камеру p2 | yaw 160 → 303 |
| `SetMovementMode(MOVE_Falling)+Velocity.Z` прыгает | z 634 → 679 → 634 |

Вывод: штатного пути «отдать второй пад второму локальному игроку» в этой игре нет — ввод
однопользовательский. Единственный рабочий путь — собственный мост: читать пад 2 и вести
пешку через `CharacterMovement`. Для действий кроме ходьбы/камеры/прыжка нужно отдельно
находить и вызывать игровые функции p1 (следующая задача).

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
- `tools/test_bridge.ps1` — автоматический прогон моста в `G:\LN2\test-install` (auto/quick/pad).
- `XInputGetState` через P/Invoke — проверка, что физические пады сидят в слотах 0 и 1.
- Компилятора нет (MSVC без заголовков/импорт-библиотек, MinGW не ставился) — поэтому всё на Lua + PowerShell + бинарный патч.
