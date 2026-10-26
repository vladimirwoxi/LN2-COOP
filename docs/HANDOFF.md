# HANDOFF — читать первым при новой сессии

Состояние на **2026-10-26**, в `mod/` стабильная **v0.6**: второй Моно управляется вторым
геймпадом (ходьба, камера, прыжок). v0.6 **установлена в игру пользователя** и проверена там
на реальном втором паде. В `wip/v0.5-bridge/` лежит исторический набросок моста, код v0.6
перенесён в `mod/Scripts/main.lua`.

## TL;DR

1. Задача: кооп Little Nightmares II **на одном ПК** (split screen, два геймпада). Игрок 2 — **второй Моно**, не Шестая.
2. Работает: второй Моно создаётся, экран делится, картинка есть у обоих, **p2 ходит со второго пада, крутит камеру правым стиком и прыгает**.
3. Главная открытая проблема теперь не ввод, а **игровая логика на одного игрока**: двери, лифты, рычаги, захваты, чекпоинты, враги. p2 пока умеет только ходить/смотреть/прыгать.
4. Второй Моно **спавнится вне уровня** и проваливается сквозь мир — лечится постановкой ровно в точку p1 (это проверенная точка на полу).
5. Ключевая хрупкость: `UE4SS.dll` **пропатчен** (21 байт) — иначе на этой сборке игры все вызовы UFunction из Lua возвращают ноль. Детали в [TECHNICAL.md](TECHNICAL.md).
6. Следующий разумный шаг: пройти `PLVL_Wilderness` вдвоём на двух падах и чинить по очереди двери/лифты/интеракции; параллельно — чекпоинт-респавн и враги.

## Что проверено в v0.6 (сессия 6)

- **Ввод пада 2 читается**: `pc2:GetInputAnalogKeyState` даёт реальные значения; в логе
  `test=false` видны движения стика, и сразу за ними позиция и скорость p2 меняются
  (`speed=130..176`, координаты уходят на сотни единиц). Это проверено на реальном втором
  паде в **установленной игре пользователя** (лог 03:39, скриншот
  `docs/img/v0.6-user-game-pad.png`), не только на тестовом файле.
- **`AddMovementInput` не работает**: при `moveIgnored=false` и `pawnIgnored=false` вызов
  (даже с `bForce=true`) не даёт ускорения — 0 единиц за 0.5 с. Игра не выполняет
  связанные действия для p2.
- **Работает запись `CharacterMovement.Velocity`**: пешка идёт с реальными коллизиями,
  склонами, гравитацией и анимацией. Мост пишет `mv.Velocity` каждые 33 мс и компенсирует
  торможение между тиками.
- **Камера**: `pc2:SetControlRotation` реально поворачивает вид p2 (yaw 160° → 303° в логе,
  нижняя половина меняется).
- **Прыжок**: `Character::Jump()` игра для p2 игнорирует; принудительный
  `SetMovementMode(MOVE_Falling)` + `Velocity.Z=420` дают прыжок (z 634 → 679 → 634).
- **Постановка**: `K2_SetActorLocationAndRotation` ровно в точку p1 **без свипа**,
  `StopMovementImmediately()`, `SetMovementMode(MOVE_Walking)`; после этого Z стабилен,
  нижняя половина рисуется. Свип и смещение в сторону не использовать: упирается в камень
  и оставляет пешку зажатой.
- **Коллизия p1/p2**: `MoveIgnoreActorAdd` на этой сборке не вызывается; работает
  `capsule:SetCollisionResponseToChannel(2 /*Pawn*/, 0 /*Ignore*/)` на капсуле p2.
  Побочный эффект: p2 проходит сквозь Шестую и врагов.

## Жёсткие ограничения (не нарушать без явного разрешения пользователя)

- **Игрок 2 = второй Моно** (`BP_PlayerPawn_C`), создаётся через `UGameplayStatics::CreatePlayer`. Шестую **нельзя** превращать во второго игрока / забирать у неё AI. Формулировка пользователя: «Не делай Шестую вторым компаньоном, сделай второго игрока как первого».
- **Split screen на одном ПК.** Онлайн/сеть не реализуем.
- Не устанавливать новое ПО (компиляторы и т.п.) без согласия пользователя.
- Игру пользователя не ломать: любые эксперименты — сначала на копии `G:\LN2\test-install`.

## Где что лежит на этой машине

| Что | Путь |
|---|---|
| Игра (установлена, с модом) | `G:\Little Nightmares 2` (bin: `Helios\Binaries\Win64`) |
| Мод в игре | `...\Win64\ue4ss\Mods\LN2Coop\` |
| Лог мода | `...\Mods\LN2Coop\LN2Coop.log` |
| Лог UE4SS | `...\ue4ss\UE4SS.log` |
| Изолированная копия для тестов | `G:\LN2\test-install` |
| Тестовые скрипты/скриншоты/пробы | `G:\LN2\local` |
| Референсы (LN1 coop, UE4SS, LN3 couch) | `G:\LN2\refs` |
| Рабочая копия мода (устарела) | `C:\Users\user\Documents\deepseek-harness\default-workspace\ln2coop` |
| **Этот репозиторий** | `C:\Users\user\Documents\deepseek-harness\default-workspace\LN2-COOP` |

GitHub-аккаунт уже авторизован: `gh auth status` → `vladimirwoxi` (scope `repo`). Клонировать: `gh repo clone vladimirwoxi/LN2-COOP`.

## Начало новой сессии (порядок действий)

1. `gh repo clone vladimirwoxi/LN2-COOP` (или `git pull` в существующей копии) — **репозиторий канонический**, рабочая копия в `C:\...\default-workspace\ln2coop` устарела и оставлена только как история.
2. Прочитать этот файл и, если нужно, `TECHNICAL.md`.
3. Проверить окружение командой ниже.
4. Дальше — по «Следующим шагам».

## Восстановление с нуля (игра без UE4SS / сломанная установка)

```powershell
gh release download v0.3 -R vladimirwoxi/LN2-COOP -p ue4ss-patched.zip -D $env:TEMP
Expand-Archive "$env:TEMP\ue4ss-patched.zip" -DestinationPath "G:\Little Nightmares 2\Helios\Binaries\Win64" -Force
powershell -ExecutionPolicy Bypass -File tools\install.ps1 -GameDir "G:\Little Nightmares 2"
```

`ue4ss-patched.zip` (15 МБ) — это `dwmapi.dll` + `ue4ss\` с уже пропатченным `UE4SS.dll` и правильным `UE4SS-settings.ini`, без дампов и `.orig`. Проверено: после распаковки хеш DLL совпадает с `A5757099…FA00A33`.

## Быстрая проверка, что окружение цело

```powershell
$b = "G:\Little Nightmares 2\Helios\Binaries\Win64"
Test-Path "$b\dwmapi.dll", "$b\ue4ss\UE4SS.dll", "$b\ue4ss\Mods\LN2Coop\Scripts\main.lua"
(Get-FileHash "$b\ue4ss\UE4SS.dll" -Algorithm SHA256).Hash
# ожидается A5757099...FA00A33 (пропатченный). Если CE5E3C46... — патч не наложен:
powershell -ExecutionPolicy Bypass -File tools\patch_ue4ss.ps1 -Dll "$b\ue4ss\UE4SS.dll"
Get-Content "$b\ue4ss\Mods\LN2Coop\coop.cfg"   # on/off
Get-Content "$b\ue4ss\Mods\mods.txt"           # LN2Coop : 1
Get-Content "$b\ue4ss\Mods\LN2Coop\LN2Coop.log" -Tail 20
```

Признак «всё сломалось» = в логе `local players 1 -> 1` и `controller=nil`: значит `ProcessEvent` снова decoy, патч потерян (обновили UE4SS или переустановили игру).

## Как тестировать

Главный инструмент — `tools/test_bridge.ps1` (Windows PowerShell 5.1, нужен полный доступ к `G:`, потому что игра и логи вне рабочей папки):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_bridge.ps1 -Mode auto
powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_bridge.ps1 -Mode quick
powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_bridge.ps1 -Mode pad -PadSeconds 15
```

- `auto` — ставит `mod\Scripts\main.lua` в `G:\LN2\test-install`, проходит в `PLVL_Wilderness`, гоняет p2 через `bridge_test.txt`: вперёд, назад, вбок, поворот камеры, прыжок; скриншоты и лог в `G:\LN2\local`.
- `quick` — только вперёд 4 с, быстрый цикл.
- `pad` — ничего не подставляет, ждёт N секунд: в это время человек двигает **левый стик второго пада**, в логе должны появиться `test=false` и рост скорости/смещение p2.
- Скрипт **перезаписывает** `ue4ss\Mods\mods.txt` в тестовой копии (оставляет только `LN2Coop : 1`) и чистит лог. В игре пользователя его не запускать.

Ручной рецепт (если скрипт недоступен):

```powershell
$bin = "G:\LN2\test-install\Helios\Binaries\Win64"
Start-Process "$bin\Little_Nightmares_II_Enhanced-Win64-Shipping.exe" -WorkingDirectory $bin
# через ~20-30 с игра в меню; ENTER продолжает игру
powershell -NoProfile -ExecutionPolicy Bypass -File G:\LN2\local\win.ps1 -Action keys -Keys ENTER
powershell -NoProfile -ExecutionPolicy Bypass -File G:\LN2\local\win.ps1 -Action shot -Out G:\LN2\local\shot.png
Get-Content "$bin\ue4ss\Mods\LN2Coop\LN2Coop.log" -Tail 40
Get-Process -Name "Little_Nightmares_II_Enhanced-Win64-Shipping" | Stop-Process -Force
```

- Загрузка уровня занимает 20–100 с: ждать в логе `player 2 placed on player 1` / `input bridge: resolved`.
- Игра встаёт на паузу без фокуса; `win.ps1 -Action shot` поднимает окно, но снять паузу надо клавишей (ENTER/Space).
- Логи читать **после** остановки процесса.
- Геймпады: два 8BitDo, XInput-слоты 0 и 1 (проверено `XInputGetState`).
- Отладочный файл моста: `...\Mods\LN2Coop\bridge_test.txt` со строкой `x,y` или
  `x,y,rx,ry,jump` (значения −1…1) подменяет пад 2; удалить файл — снова реальный пад.
  Это только для тестов, игрокам не нужно.

## Грабли (уже наступлено)

1. **`HookInitGameState = 1` и `HookProcessConsoleExec = 1` роняют игру** на этой сборке. В `UE4SS-settings.ini` должно быть `0`. Полный рабочий конфиг — в игре (`ue4ss\UE4SS-settings.ini`), ключевые значения: `bUseUObjectArrayCache = false`, `DefaultExecuteInGameThreadMethod = EngineTick`, `DefaultFNameToStringMethod = Scan`, `ConsoleEnabled/GuiConsole*=0`, `MaxMemoryUsageDuringAssetLoading = 80`.
2. **UE4SS 3.0.1 stable падает на старте** (нет event loop) — нужен experimental build (`v3.0.1-1181-g83330635`).
3. **`dwmapi.dll` должен лежать рядом с exe игры**, а не в корне игры.
4. **Путь для `coop.cfg`/лога не брать из cwd** (cwd = `Win64`): путь вычисляется из `debug.getinfo(1,"S").source`.
5. **BOM в `.lua` ломает скрипт.** Писать UTF-8 без BOM (`Set-Content -Encoding utf8` на PS 5.1 добавляет BOM — использовать `[IO.File]::WriteAllText` с `UTF8Encoding($false)`). `.ps1` — ASCII без BOM.
6. **Не патчить общую заглушку `0xA0C0A0`** — игра сама её использует, процесс умирает.
7. `RemovePlayer` для отключения второго игрока — на LN1 крашило, здесь не проверялось. Безопаснее просто не создавать P2.
8. Оболочка инструментов = **Windows PowerShell 5.1**, не pwsh: `pwsh` внутри нет, запускать `powershell -NoProfile -ExecutionPolicy Bypass -File script.ps1`.
9. **`AddMovementInput` на p2 не работает** даже с `bForce=true`: `IsMoveInputIgnored()`/`pawn:IsMoveInputIgnored()` = `false`, но смещения 0. Не тратить время на «правильный» ввод — писать `mv.Velocity`.
10. **`MoveIgnoreActorAdd` не вызывается** на этой сборке. Для p1/p2 использовать `SetCollisionResponseToChannel(2, 0)` на капсуле p2.
11. **Смещение p2 в сторону при спавне опасно**: свип 45 см упирается в камень после 13 см, пешка зажимается; ставить ровно в p1 и оставлять наложение до первого движения.
12. **`Character::Jump()` для p2 не срабатывает**: только `SetMovementMode(MOVE_Falling)` + `Velocity.Z`.
13. **`K2_SetActorLocationAndRotation` без свипа сохраняет старую скорость**: после телепорта обязательно `StopMovementImmediately()`.
14. **`p2 state` в логе** — 1 строка/с: позиция, скорость, режим движения, yaw/pitch, стики, `test`. По ней проверяется мост.

## Следующие шаги (по приоритету)

1. **Прохождение вдвоём** на двух падах: `PLVL_Wilderness` и дальше. Фиксировать в `SESSION-LOG.md`, что сломалось (двери, лифты, вышки, сценарий, чекпоинты).
2. **Интеракции p2**: захват/подъём предметов, рычаги, двери, кнопки. Нужно найти функции, которые игра вызывает у p1 (вероятно, на `BP_PlayerPawnController_C`/`BP_PlayerPawn_C`), и пробросить их из моста по кнопке (сейчас `Gamepad_FaceButton_Left` уже резолвится, но не используется).
3. **Чекпоинт-респавн с двумя игроками**: убедиться, что после смерти/загрузки оба живы, p2 снова ставится в p1 и мост оживает.
4. **Враг-таргетинг**: проверить, что враги реагируют на второго (иначе P2 — невидимка).
5. **Коллизия p2 с Шестой/врагами**: сейчас канал Pawn игнорируется; либо вернуть Block после первого движения, либо завести отдельный канал.
6. **Удобство**: переключатель коопа без перезапуска (клавиша/пункт меню), скрытие P2 при `off`, возврат игрока в одну камеру.
7. **Полировка p2**: проверить поворот модели к направлению движения, анимацию прыжка, поведение на лестницах/склонах.
8. **Отдать в coop-anything** (playbook `github.com/cranebeaker/coop-anything`): запись в `data/directory.yaml`, `games/little-nightmares-2/README.md`, PR. **Требуется разрешение пользователя на публикацию** — пока не сделано.

## Соглашения репозитория

- Знание, найденное в сессии, дописывать сюда или в `TECHNICAL.md` **в той же сессии**, а не «потом».
- Версии: поднимать `vX.Y` в `main.lua` (`log("v0.6 loaded ...")`), `CHANGELOG.md`, `README.md`, релиз на GitHub.
- Изменения мода: править `mod/` в репозитории → `tools/install.ps1` → проверка в игре. Не править файлы прямо в игре «на живую» дольше, чем на один тест.

## Ссылки

- [TECHNICAL.md](TECHNICAL.md) — ProcessEvent, RVA, хеши, UE4SS настройки, мост ввода p2.
- [SESSION-LOG.md](SESSION-LOG.md) — хронология: что пробовали и чем закончилось.
- `tools/test_bridge.ps1` — автотест моста (auto/quick/pad).
- `G:\LN2\refs\little-nightmares-1-coop\AtlasCoop\Scripts\main.lua` — LN1 split-screen мод (телепорт, парковка, меню, аспект): образец похожего решения.
- `G:\LN2\refs\ln3couch` — LN3 couch co-op: второй игрок через отдельный мост/ИИ, много готовых решений для камеры, смерти, респавна.
- `G:\LN2\refs\RE-UE4SS` — исходники UE4SS (клон), `G:\Little Nightmares 2\ue4ss\Docs\lua-api.md` — API.
- Документация UE4SS: `fixing-compatibility-problems.md` — ProcessEvent **нельзя** переопределить через AOB, поэтому и понадобился бинарный патч.
