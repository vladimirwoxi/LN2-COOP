LN2Coop 0.6.1 — Little Nightmares II, split-screen co-op on one PC
===============================================================

Репозиторий проекта (private): https://github.com/vladimirwoxi/LN2-COOP
Там же: docs\HANDOFF.md (состояние проекта), docs\TECHNICAL.md (патч UE4SS),
релизы с готовыми архивами и скрипт установки.

Что это
-------
Кооператив на одном ПК: два игрока, разделённый экран, два геймпада.
Второй игрок — ВТОРОЙ МОНО: игра сама спавнит для него такой же
BP_PlayerPawn (та же модель, те же способности, свой контроллер и своя
камера). Шестая при этом остаётся управляемой игрой AI-спутницей — мод её
не трогает.

Экран делится на две половины, у каждой своя камера и свой геймпад:
  игрок 1 — геймпад, который игра выбрала первой,
  игрок 2 — второй геймпад (ControllerId = 1).

Как играть
----------
1. Подключите ОБА геймпада до запуска игры.
2. Запустите игру как обычно (GOG/ярлык). Мод включается сам.
3. Продолжите игру. Когда загрузится уровень, появится второй Моно и
   экран разделится.

Управление игроком 2
--------------------
  левый стик  — ходьба,
  X           — спринт (удерживать),
  правый стик — камера,
  A           — прыжок.

В момент появления второй Моно стоит точно в точке первого: это проверенная
точка на полу, иначе пешка оказывается вне уровня и проваливается. Двиньте
левый стик — и он отделится и пойдёт сам.

Подбор предметов и взаимодействия (захват, двери, рычаги) пока НЕ работают:
игра не выполняет свои действия для второго игрока, их нужно подключать
отдельно.

Выключить кооп (играть одному)
------------------------------
В папке мода есть файл coop.cfg. Напишите в нём off (или 0) и перезапустите
игру — второй игрок создаваться не будет. on (или 1) — включить обратно.

Где что лежит
-------------
<игра>\Helios\Binaries\Win64\
  dwmapi.dll                     загрузчик UE4SS
  ue4ss\                         UE4SS + мод
    UE4SS.dll                    ПРОПАТЧЕННЫЙ (см. ниже)
    UE4SS.dll.orig               исходный, нетронутый UE4SS.dll
    Mods\LN2Coop\                сам мод
      Scripts\main.lua
      coop.cfg                   on / off
      LN2Coop.log                лог мода (что он сделал)

Важно про UE4SS
---------------
В этой игре UE4SS штатно находит не ту функцию UObject::ProcessEvent
(ложная сигнатура: попадает на пустую заглушку xor eax,eax; ret). Из-за
этого ЛЮБОЙ вызов UFunction из Lua молча возвращает ноль, и создать
второго локального игрока невозможно.

Поэтому UE4SS.dll пропатчен: функция RC::Unreal::UObject::ProcessEvent
(RVA 0x3ECCC0) заменена на короткий переход к настоящему ProcessEvent игры
(RVA 0x2875080, вычисляется от базы модуля, так что ASLR не мешает).
Патч не трогает саму игру — только слой UE4SS, который и так вызывает
ProcessEvent.

Оригинал сохранён как UE4SS.dll.orig. Если UE4SS будет обновлён, патч
нужно наложить заново — для этого рядом лежит patch_ue4ss.ps1.

Известные ограничения (проверено на стартовом уровне)
-----------------------------------------------------
* Проверены: создание второго Моно, разделение экрана, ходьба/спринт (X)/
  камера/прыжок (A) со второго пада, постановка на пол. Полное прохождение
  вдвоём ещё не пройдено.
* Подбор предметов и взаимодействия второго игрока (захват, подъём, двери,
  рычаги) НЕ работают — игра выполняет свои действия только для первого
  игрока.
* Сюжетные скрипты, двери, лифты и враги рассчитаны на одного игрока.
  Если где-то второй игрок останется за дверью/в лифте — это ограничение
  мода, а не поломка; перезапуск уровня помогает.
* Капсула второго Моно игнорирует столкновения с другими персонажами,
  чтобы два Моно не блокировали друг друга в точке спавна. Побочный эффект:
  p2 проходит сквозь Шестую и врагов.
* Игра ставится на паузу, когда окно теряет фокус (это поведение самой
  игры). Нажмите «Продолжить» (или Enter), когда вернётесь в окно.
* Если геймпады переподключить в другом порядке, игроки могут поменяться
  местами — перезапустите игру.
* Мод не работает без патча UE4SS.dll (см. ниже).

Как это работает (коротко)
--------------------------
Мод на Lua через UE4SS:
  * при загрузке игрового уровня (PLVL_*) включает bUseSplitscreen и
    вызывает UGameplayStatics::CreatePlayer для ControllerId 1;
  * игра сама спавнит второму игроку BP_PlayerPawnController + BP_PlayerPawn
    (Моно) и его камеру;
  * мод ставит второго Моно точно в точку первого (проверенная точка на
    полу), обнуляет скорость и переводит в режим ходьбы;
  * игра не выполняет свои действия для второго игрока, поэтому мод сам
    читает второй пад и ведёт пешку: пишет CharacterMovement.Velocity для
    ходьбы (210) и спринта (360, кнопка X), переворачивает сырые оси стика
    (на этой сборке они инвертированы), крутит камеру через SetControlRotation,
    прыгает через MOVE_Falling + вертикальную скорость (A);
  * на смене уровня всё повторяется; в меню разделение выключается.

Удаление
--------
Удалите папку ue4ss\Mods\LN2Coop и строку LN2Coop в ue4ss\Mods\mods.txt.
Чтобы убрать UE4SS полностью: удалите dwmapi.dll и папку ue4ss рядом с
Little_Nightmares_II_Enhanced-Win64-Shipping.exe (перед этим верните
UE4SS.dll.orig, если хотите оставить UE4SS без патча).

------------------------------------------------------------------------------

LN2Coop 0.6.1 — English
----------------------
Same-PC split-screen co-op for Little Nightmares II (Enhanced Edition).
Player 2 is a second Mono: the game's own game mode spawns a second
BP_PlayerPawn with its own controller and camera. Six is never touched and
stays the game's AI companion.

Connect both gamepads before launching. Start the game normally, continue,
and once a level loads the second Mono appears and the screen splits.

Player 2 controls: left stick walks, X sprints, right stick turns the camera, A jumps.
The game runs none of its own actions for player 2, so the mod reads pad 2
and drives the pawn itself (CharacterMovement.Velocity, SetControlRotation,
MOVE_Falling + vertical velocity). The raw stick axes are inverted on this
build, so both movement axes are flipped. Picking up items and other
interactions (grab, doors, levers) are not wired yet. Player 2 is placed
exactly on player 1's known-good floor spot and will overlap player 1 until
you move the left stick.

Set "off" in coop.cfg to disable co-op.

UE4SS.dll in this folder is patched: its RC::Unreal::UObject::ProcessEvent
wrapper (RVA 0x3ECCC0) jumps to the game's real ProcessEvent (RVA 0x2875080,
resolved through the main module base). Without that patch every Lua
UFunction call silently returns zero on this build. UE4SS.dll.orig is the
untouched original; patch_ue4ss.ps1 re-applies the patch.

Tested: second Mono creation, split screen, placement, level start, walking
forward/back/strafe from pad 2, sprint on X, camera yaw, jump on A, on the
user's installed game. Picking up items and other interactions do not work
yet; doors, lifts and enemies are still single-player logic. The game pauses
when its window loses focus.
