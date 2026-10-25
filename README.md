# LN2 COOP

**Кооператив на одном ПК для Little Nightmares II** (Enhanced Edition, GOG) — разделённый экран, два геймпада, второй игрок это **второй Моно**.

![Разделённый экран: два Моно, у каждого своя половина](docs/img/split-screen.png)

`v0.3` · рабочий прототип · UE 4.26 · UE4SS Lua

---

## Кратко: что сделано

- **Split screen на одном ПК.** Второй игрок создаётся штатным `UGameplayStatics::CreatePlayer` — игра сама спавнит ему `BP_PlayerPawnController_C`, такой же `BP_PlayerPawn_C` (Моно) и отдельную камеру. Сеть не нужна, нужны два геймпада.
- **Второй игрок — второй Моно, а не Шестая.** Шестая не тронута: остаётся управляемой игрой AI-спутницей со своим `BP_SixPawn_C` / `BP_PlaypalAIController_C`.
- **Мод на Lua через UE4SS**, ~270 строк: при загрузке игрового уровня включает `bUseSplitscreen`, создаёт второго локального игрока (ControllerId 1) и ставит его рядом с первым, чтобы Моно не спавнились друг в друге. В меню разделение экрана выключается.
- **Найден и обойдён баг UE4SS на этой сборке игры.** UE4SS находил вместо `UObject::ProcessEvent` пустую заглушку `xor eax,eax; ret`, из-за чего *любой* вызов UFunction из Lua молча возвращал ноль (`Add_IntInt(2,3)` → `0`, `CreatePlayer` → `nil`), и второй игрок не создавался в принципе. `UE4SS.dll` пропатчен 21 байтом: обёртка → настоящий `ProcessEvent` игры (RVA `0x2875080`), ASLR-безопасно. Подробности и доказательства: [docs/TECHNICAL.md](docs/TECHNICAL.md).
- **Мод установлен и проверен в реальной игре**: 1 → 2 локальных игрока, `ControllerId = 1`, `PlayerInput = HeliosPlayerInput`, pawn `BP_PlayerPawn_C`, экран разделён, оба Моно видны.

## Что работает (проверено в игре)

| Проверено | Как проверено |
|---|---|
| Создание второго локального игрока | лог мода: `local players 1 -> 2`, `controller id=1 input=HeliosPlayerInput` |
| Второй игрок — Моно, не Шестая | pawn второго игрока `BP_PlayerPawn_C` |
| Разделённый экран, у каждой половины своя камера | скриншот, две независимые камеры |
| Расстановка без наложения | `player 2 placed beside player 1 at ...` |
| Старт уровня и переход из меню | `BootupMenu` → `LVL_MainMenu` → `PLVL_Wilderness` |
| Меню не разделяется | `bUseSplitscreen = false` вне `PLVL_*` |
| Перезапуск игры/уровня | второй Моно создаётся заново на upkeep |

## Что ещё не проверено

- Полное прохождение вдвоём: двери, лифты, сюжетные сцены, чекпоинт-респавн с двумя игроками, перенацеливание врагов. Игра во многом рассчитана на одного игрока — где-то второй может остаться за дверью.
- Ввод с двух **физических** геймпадов (раскладка проверялась только по `ControllerId`/`PlayerInput`; headless-тест не может нажать кнопку на втором паде).
- Включение/выключение коопа без перезапуска игры и скрытие второго Моно при выключении.

## Установка

Нужны: лицензионная **Little Nightmares II Enhanced Edition** (GOG или Steam, сборка ниже) и **два геймпада**.

1. Скачать из [Releases](../../releases) архив `ue4ss-patched.zip` и распаковать его в `<игра>\Helios\Binaries\Win64\` — там появятся `dwmapi.dll` и папка `ue4ss\` с уже пропатченным `UE4SS.dll`.
2. Разложить мод:

```powershell
powershell -ExecutionPolicy Bypass -File tools\install.ps1 -GameDir "G:\Little Nightmares 2"
```

Скрипт копирует мод в `ue4ss\Mods\LN2Coop\`, прописывает `LN2Coop : 1` в `Mods\mods.txt`, проверяет хеш `UE4SS.dll` и при необходимости накладывает патч (`tools\patch_ue4ss.ps1`, проверяет SHA-256 и версию игры, делает бэкап `.orig`). Есть `-DryRun`.

Итоговая раскладка:

```
<игра>\Helios\Binaries\Win64\
  dwmapi.dll                 загрузчик UE4SS (proxy)
  Little_Nightmares_II_Enhanced-Win64-Shipping.exe
  ue4ss\
    UE4SS.dll                пропатченный (оригинал — UE4SS.dll.orig)
    UE4SS-settings.ini       настройки под эту сборку
    Mods\
      mods.txt               LN2Coop : 1
      LN2Coop\
        Scripts\main.lua     сам мод
        coop.cfg             on / off
        LN2Coop.log          лог мода
        README.txt
        patch_ue4ss.ps1
```

## Как играть

1. Подключите **оба геймпада до запуска** игры.
2. Запустите игру как обычно (GOG/ярлык/Steam).
3. «Продолжить». Когда загрузится уровень — появится второй Моно и экран разделится (игрок 1 сверху, игрок 2 снизу).

Игрок 2 — второй геймпад (`ControllerId = 1`).

## Выключить кооп

В `ue4ss\Mods\LN2Coop\coop.cfg` написать `off` (или `0`) и перезапустить игру. `on` / `1` — обратно.

## Структура репозитория

```
README.md              эта сводка
CHANGELOG.md           история версий
mod/                   исходники мода (то, что лежит в игре)
  Scripts/main.lua
  coop.cfg, README.txt, mods.txt
tools/
  install.ps1          раскладка мода в установленную игру + проверка патча
  patch_ue4ss.ps1      патч UE4SS.dll (хеши, PE-маппинг, бэкап)
docs/
  HANDOFF.md           ⬅ для новой сессии: состояние, решения, следующие шаги
  TECHNICAL.md         разбор ProcessEvent, RVA, хеши, настройки UE4SS
  SESSION-LOG.md       хронология работ
  img/split-screen.png
```

## Новая сессия — начните здесь

Всё, что нужно для продолжения работы (состояние, что проверено, чего не хватает, грабли, адреса, команды), собрано в **[docs/HANDOFF.md](docs/HANDOFF.md)**. Технический разбор — в [docs/TECHNICAL.md](docs/TECHNICAL.md).

## Удаление

Удалите `ue4ss\Mods\LN2Coop` и строку `LN2Coop` из `Mods\mods.txt`. Полностью убрать UE4SS — удалить `dwmapi.dll` и папку `ue4ss\` (вернув `UE4SS.dll.orig` на место `UE4SS.dll`, если он нужен без патча).

## Ограничения и предупреждения

- Патч `UE4SS.dll` **привязан к сборке игры** (SHA-256 exe проверяется скриптом). После обновления игры или UE4SS патч нужно накладывать заново/перепроверять.
- Игра ставится на паузу, когда окно теряет фокус — это поведение самой игры, нажмите «Продолжить».
- Мод меняет только клиентскую сторону; никакой сетевой игры нет.

---

## English (short)

Same-PC split-screen co-op for **Little Nightmares II Enhanced Edition**. Player 2 is a *second Mono*: the game's own game mode spawns a second `BP_PlayerPawn` with its own controller and camera. Six is never touched and stays the AI companion. Two gamepads, no networking.

The bundled `UE4SS.dll` is patched: on this build UE4SS's `ProcessEvent` scan resolves to an empty stub (`xor eax,eax; ret`), so every Lua UFunction call silently returned zero and no second local player could be created. A 21-byte stub redirects UE4SS's wrapper (RVA `0x3ECCC0`) to the game's real `UObject::ProcessEvent` (RVA `0x2875080`), ASLR-safe.

Tested: second local player creation, split screen with two cameras, level start, menu handling. Not tested: full two-player playthrough (doors, lifts, scripted sequences, enemies), physical pad-2 input.

Read [docs/HANDOFF.md](docs/HANDOFF.md) first when resuming work.
