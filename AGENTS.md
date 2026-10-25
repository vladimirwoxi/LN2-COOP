# AGENTS.md — правила работы в этом репозитории

Это единственный источник правды по проекту **LN2 COOP** (кооп Little Nightmares II на одном ПК, split screen). Новая сессия ИИ начинает с чтения **[docs/HANDOFF.md](docs/HANDOFF.md)**.

## Что читать и в каком порядке

1. [docs/HANDOFF.md](docs/HANDOFF.md) — состояние, ограничения, следующие шаги, грабли.
2. [docs/TECHNICAL.md](docs/TECHNICAL.md) — ProcessEvent, патч `UE4SS.dll`, RVA, хеши, настройки.
3. [docs/SESSION-LOG.md](docs/SESSION-LOG.md) — что уже пробовали (чтобы не повторять).
4. `mod/Scripts/main.lua` — сам мод.

## Жёсткие ограничения (менять только по прямой просьбе пользователя)

- Игрок 2 — **второй Моно** (`BP_PlayerPawn_C`) через `UGameplayStatics::CreatePlayer`. Шестую не переделывать во второго игрока, её AI не трогать.
- **Split screen на одном ПК.** Сетевую игру не делать.
- Игру пользователя (`G:\Little Nightmares 2`) не ломать: эксперименты — на копии (`G:\LN2\test-install`), установка — через `tools/install.ps1`.
- Не ставить новое ПО (компиляторы, SDK) без согласия пользователя.

## Рабочий цикл

```
правим mod/  →  powershell -File tools\install.ps1 -GameDir "G:\Little Nightmares 2"
             →  запуск игры + проверка (лог LN2Coop.log, скриншоты)
             →  обновить CHANGELOG.md, docs/HANDOFF.md, docs/SESSION-LOG.md
             →  commit + push;  при смене версии — релиз и zip в нём
```

- Правим **только** `mod/` в репозитории, потом раскладываем скриптом. Не жить правками в игре.
- Тексты `.ps1` — **ASCII без BOM** (PowerShell 5.1). `.lua` — UTF-8 **без BOM**.
- Версия мода видна в `log("v0.3 loaded ...")` в `main.lua`; поднимать её вместе с `CHANGELOG.md`.

## Что считается сделанным

Фича готова, когда: (1) проверена в реальной игре, (2) есть запись в логе мода или скриншот, (3) отражена в `HANDOFF.md`/`CHANGELOG.md`. «Должно работать» — не готово.

## Окружение этой машины

- Windows, оболочка инструментов = **Windows PowerShell 5.1** (`pwsh` внутри нет) → `powershell -NoProfile -ExecutionPolicy Bypass -File ...`.
- Игра: `G:\Little Nightmares 2\Helios\Binaries\Win64`. Тестовая копия: `G:\LN2\test-install`. Референсы: `G:\LN2\refs`.
- `gh` авторизован (`vladimirwoxi`, scope `repo`) → можно клонировать, пушить, качать релизы.
- Игра встаёт на паузу при потере фокуса — перед скриншотом вернуть фокус и нажать Enter.
- Лог мода: `<bin>\ue4ss\Mods\LN2Coop\LN2Coop.log`; признак потери патча — `local players 1 -> 1`.

## Backlog пользователя

Прохождение вдвоём, двери/лифты, чекпоинты, враги, переключатель коопа без перезапуска, отдача в `coop-anything`. Подробно — в [HANDOFF.md](docs/HANDOFF.md#следующие-шаги-по-приоритету).
