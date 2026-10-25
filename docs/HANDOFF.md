# HANDOFF — читать первым при новой сессии

Состояние на **2026-10-26**, мод **v0.3**, репозиторий `vladimirwoxi/LN2-COOP` (private).

## TL;DR

1. Задача: кооп Little Nightmares II **на одном ПК** (split screen, два геймпада). Игрок 2 — **второй Моно**, не Шестая.
2. Оно **работает**: второй Моно создаётся, экран делится, уровень стартует. Прототип установлен в игру пользователя.
3. Полное прохождение вдвоём **не проверено** — двери/лифты/сценарий/враги рассчитаны на одного.
4. Ключевая хрупкость: `UE4SS.dll` **пропатчен** (21 байт) — иначе на этой сборке игры все вызовы UFunction из Lua возвращают ноль. Детали в [TECHNICAL.md](TECHNICAL.md).
5. Следующий разумный шаг: пройти уровень-два вдвоём с двумя падами и починить то, что сломается (двери/лифты/чекпоинты), начиная с `PLVL_Wilderness`.

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
| Рабочая копия мода | `C:\Users\user\Documents\deepseek-harness\default-workspace\ln2coop` |
| **Этот репозиторий** | `C:\Users\user\Documents\deepseek-harness\default-workspace\LN2-COOP` |

GitHub-аккаунт уже авторизован: `gh auth status` → `vladimirwoxi` (scope `repo`). Клонировать: `gh repo clone vladimirwoxi/LN2-COOP`.

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

## Как тестировать (без физических падов не всё проверяемо)

- Запуск: `Start-Process "$b\Little_Nightmares_II_Enhanced-Win64-Shipping.exe" -WorkingDirectory $b`.
- Игра **ставится на паузу при потере фокуса** — перед скриншотом вернуть фокус окну и нажать Enter (или «Продолжить»).
- Скриншоты и нажатия: `G:\LN2\local\win.ps1` (`/shot`, `/key`, `/focus`).
- Проверка Lua-вызовов в игре — через пробы: положить временный мод/скрипт, вызвать `Add_IntInt(2,3)` → должно быть `5`. Если `0` — патч не работает.
- Логи читать **после** остановки процесса: `Stop-Process -Name Little_Nightmares_II_Enhanced-Win64-Shipping -Force`.

## Грабли (уже наступлено)

1. **`HookInitGameState = 1` и `HookProcessConsoleExec = 1` роняют игру** на этой сборке. В `UE4SS-settings.ini` должно быть `0`. Полный рабочий конфиг — в игре (`ue4ss\UE4SS-settings.ini`), ключевые значения: `bUseUObjectArrayCache = false`, `DefaultExecuteInGameThreadMethod = EngineTick`, `DefaultFNameToStringMethod = Scan`, `ConsoleEnabled/GuiConsole* = 0`, `MaxMemoryUsageDuringAssetLoading = 80`.
2. **UE4SS 3.0.1 stable падает на старте** (нет event loop) — нужен experimental build (`v3.0.1-1181-g83330635`).
3. **`dwmapi.dll` должен лежать рядом с exe игры**, а не в корне игры.
4. **Путь для `coop.cfg`/лога не брать из cwd** (cwd = `Win64`): путь вычисляется из `debug.getinfo(1,"S").source`.
5. **BOM в `.lua` ломает скрипт.** Писать UTF-8 без BOM (`Set-Content -Encoding utf8` на PS 5.1 добавляет BOM — использовать `[IO.File]::WriteAllText` с `UTF8Encoding($false)`).
6. **Не патчить общую заглушку `0xA0C0A0`** — игра сама её использует, процесс умирает.
7. `RemovePlayer` для отключения второго игрока — на LN1 крашило, здесь не проверялось. Безопаснее просто не создавать P2.
8. Оболочка инструментов = **Windows PowerShell 5.1**, не pwsh: `pwsh` внутри нет, запускать `powershell -NoProfile -ExecutionPolicy Bypass -File script.ps1`.

## Следующие шаги (по приоритету)

1. **Прохождение вдвоём** на двух падах: `PLVL_Wilderness` и дальше. Фиксировать в `SESSION-LOG.md`, что сломалось (двери, лифты, вышки, сценарий, чекпоинты).
2. **Двери/лифты/интеракции**: искать в игре места, где логика проверяет одного игрока (`NumPlayers`, `GetPlayerPawn(0)`), и адаптировать — вероятно, через подмену/дублирование или принудительное выполнение триггера по второму игроку.
3. **Чекпоинт-респавн с двумя игроками**: убедиться, что после смерти/загрузки оба живы и стоят рядом.
4. **Враг-таргетинг**: проверить, что враги реагируют на второго (иначе P2 — невидимка).
5. **Удобство**: переключатель коопа без перезапуска (клавиша/пункт меню), скрытие P2 при `off`, возврат игрока в одну камеру.
6. **Отдать в coop-anything** (playbook `github.com/cranebeaker/coop-anything`): запись в `data/directory.yaml`, `games/little-nightmares-2/README.md`, PR. **Требуется разрешение пользователя на публикацию** — пока не сделано.

## Соглашения репозитория

- Знание, найденное в сессии, дописывать сюда или в `TECHNICAL.md` **в той же сессии**, а не «потом».
- Версии: поднимать `vX.Y` в `main.lua` (`log("v0.3 loaded ...")`), `CHANGELOG.md`, `README.md`, релиз на GitHub.
- Изменения мода: править `mod/` в репозитории → `tools/install.ps1` → проверка в игре. Не править файлы прямо в игре «на живую» дольше, чем на один тест.

## Ссылки

- [TECHNICAL.md](TECHNICAL.md) — ProcessEvent, RVA, хеши, UE4SS настройки, проверенные структуры.
- [SESSION-LOG.md](SESSION-LOG.md) — хронология: что пробовали и чем закончилось.
- `G:\LN2\refs\little-nightmares-1-coop\AtlasCoop\Scripts\main.lua` — LN1 split-screen мод (телепорт, парковка, меню, аспект): лучший образец похожего решения.
- `G:\LN2\refs\RE-UE4SS` — исходники UE4SS (клон), `G:\Little Nightmares 2\ue4ss\Docs\lua-api.md` — API.
- Документация UE4SS: `fixing-compatibility-problems.md` — ProcessEvent **нельзя** переопределить через AOB, поэтому и понадобился бинарный патч.
