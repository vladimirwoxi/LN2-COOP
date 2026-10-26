-- LN2Coop v0.2 - same-PC split-screen co-op for Little Nightmares II (Enhanced Edition)
--
-- Player 2 is a *second Mono*: the game's own game mode spawns a second BP_PlayerPawn
-- (same class as player 1) together with its own BP_PlayerPawnController and camera.
-- Six is never touched: she stays the game's AI companion, controlled by her own AI.
--
-- The second local player is created when a gameplay level is up. The two Monos are
-- placed side by side so they do not spawn inside each other.
--
-- Requires a UE4SS whose UObject::ProcessEvent wrapper points at the game's real
-- ProcessEvent (the installer patches UE4SS.dll for that). Without the patch every
-- UFunction call silently returns zero and no second local player can be created.
--
-- co-op can be switched off with a file "coop.cfg" next to this mod:
--   on   (default) - split-screen co-op
--   off            - the game stays single-player (no second Mono is created)

local CONFIG = {
    -- gamepad index for player 2 (player 1 keeps the pad the game gave it)
    pad2 = 1,
    -- player 2 is placed this far to player 1's right when a level starts
    spawnSideOffset = 80.0,
    -- how often the upkeep runs, milliseconds
    interval = 2000,
    -- the level has no player start for a second player, so player 2 can drop through
    -- the floor; if it ends up this far below player 1 it is put back next to them
    dropLimit = 1200.0,
    -- and if it strays this far away horizontally it is brought back as well
    maxDistance = 2500.0,
    -- do not teleport more often than this, seconds
    replaceCooldown = 6,
    -- how often the player 2 input bridge runs, milliseconds
    bridgeInterval = 50,
    -- map gamepad 2 to local player 2 (UGameMapsSettings.bOffsetPlayerGamepadIds)
    offsetGamepadIds = false,
}

local TAG = "[LN2Coop]"

-- Find this mod's own folder so the config and the log land next to the mod no matter
-- which directory the game was started from.
local MOD_DIR = nil
do
    -- the chunk name is the full path of this script
    local src = nil
    pcall(function() src = debug.getinfo(1, "S").source end)
    if src then
        local dir = src:match("^@(.+)[/\\]Scripts[/\\]main%.lua$")
        if dir then MOD_DIR = dir end
    end
    if not MOD_DIR and io.open("ue4ss/Mods/LN2Coop/Scripts/main.lua", "r") then MOD_DIR = "ue4ss/Mods/LN2Coop" end
    if not MOD_DIR then MOD_DIR = "Mods/LN2Coop" end
end
local LOG_PATH = MOD_DIR .. "/LN2Coop.log"

local function log(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    local line = TAG .. " " .. (ok and s or tostring(fmt))
    print(line .. "\n")
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("%H:%M:%S ") .. line .. "\n") f:close() end
end

local function readEnabled()
    local f = io.open(MOD_DIR .. "/coop.cfg", "r")
    if not f then return true end
    local s = f:read("*a") or ""
    f:close()
    s = s:lower()
    if s:find("off", 1, true) or s:find("0", 1, true) then return false end
    return true
end

CONFIG.enabled = readEnabled()

local function isLive(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local function fullName(o)
    local ok, n = pcall(function() return o and o:GetFullName() end)
    return ok and n or "<nil>"
end

local function locOf(actor)
    local ok, v = pcall(function() return actor:K2_GetActorLocation() end)
    if ok and v then return v end
    return nil
end

local gs, gms
local lastWorld = ""
local placedForWorld = nil
local lastCreate = 0
local loggedInput = false
local lastReplace = 0
local clientRestarted = false
local P2 = nil

local function ensureSingletons()
    if not isLive(gs) then
        local ok, o = pcall(function() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end)
        if ok then gs = o end
    end
    if not isLive(gms) then
        local ok, o = pcall(function() return StaticFindObject("/Script/EngineSettings.Default__GameMapsSettings") end)
        if ok then gms = o end
    end
end

-- All live player controllers, ordered by local-player slot: slot 1 is the game's own
-- player, slot 2 the one this mod created.
local function getPlayers()
    local list = {}
    local ok, all = pcall(function() return FindAllOf("PlayerController") end)
    if not ok or not all then return list end
    local lps = nil
    for _, pc in pairs(all) do
        if isLive(pc) then
            local w = nil
            pcall(function() w = pc:GetWorld() end)
            if isLive(w) then
                local gi = nil
                pcall(function() gi = w.OwningGameInstance end)
                if isLive(gi) then pcall(function() lps = gi.LocalPlayers end) end
            end
            break
        end
    end
    local slot = {}
    if lps then
        for i = 1, #lps do
            local lp, opc = nil, nil
            pcall(function() lp = lps[i] end)
            pcall(function() opc = lp.PlayerController end)
            if isLive(opc) then slot[fullName(opc)] = i end
        end
    end
    for _, pc in pairs(all) do
        if isLive(pc) then
            local pawn, id = nil, -1
            pcall(function() pawn = pc.Pawn end)
            pcall(function() id = pc.Player.ControllerId end)
            list[#list + 1] = { pc = pc, pawn = pawn, id = id, slot = slot[fullName(pc)] or 99 }
        end
    end
    table.sort(list, function(a, b)
        if a.slot ~= b.slot then return a.slot < b.slot end
        return a.id < b.id
    end)
    return list
end

local function localPlayerCount(players)
    local pc = players[1] and players[1].pc
    if not isLive(pc) then return 0 end
    local w, gi, lps, n = nil, nil, nil, 0
    pcall(function() w = pc:GetWorld() end)
    if isLive(w) then pcall(function() gi = w.OwningGameInstance end) end
    if not isLive(gi) then return 0 end
    pcall(function() lps = gi.LocalPlayers end)
    pcall(function() n = #lps end)
    return n
end

local function isGameplayWorld(name)
    return type(name) == "string" and name:find("PLVL_", 1, true) ~= nil
end

local function isMonoPawn(pawn)
    if not isLive(pawn) then return false end
    local n = fullName(pawn)
    return n:find("BP_PlayerPawn_C", 1, true) ~= nil and not n:find("SixPawn", 1, true)
end

-- Put player 2 beside player 1 (same height, to the right) instead of inside them.
-- Swept: if the spot is inside a wall/rock the engine slides the pawn out instead of
-- leaving it embedded, which used to make player 2 look frozen.
local function placePlayer2(p1, p2, reason)
    if not (isLive(p1.pawn) and isLive(p2.pawn)) then return false end
    local l1 = locOf(p1.pawn)
    if not l1 then return false end
    local right = nil
    pcall(function() right = p1.pawn:GetActorRightVector() end)
    local rx, ry = 0, 0
    if type(right) == "table" then rx, ry = right.X or 0, right.Y or 0 end
    if rx == 0 and ry == 0 then rx = 1 end
    local spot = {
        X = l1.X + rx * CONFIG.spawnSideOffset,
        Y = l1.Y + ry * CONFIG.spawnSideOffset,
        Z = l1.Z + 60.0,
    }
    local rot = nil
    pcall(function() rot = p1.pawn:K2_GetActorRotation() end)
    local moved = false
    local okSweep = pcall(function()
        p2.pawn:K2_SetActorLocationAndRotation(spot, rot, true, {}, true)
    end)
    if okSweep then
        moved = true
    else
        pcall(function()
            p2.pawn:K2_SetActorLocationAndRotation(spot, rot, false, {}, true)
        end)
    end
    -- last resort: exactly on player 1 (the game will push them apart)
    if not moved then
        pcall(function() p2.pawn:K2_SetActorLocationAndRotation(l1, rot, false, {}, true) end)
    end
    log("player 2 placed beside player 1 (%s) at %.0f %.0f %.0f", tostring(reason), spot.X, spot.Y, spot.Z)
    return true
end

local function distance2d(a, b)
    local dx, dy = (a.X or 0) - (b.X or 0), (a.Y or 0) - (b.Y or 0)
    return math.sqrt(dx * dx + dy * dy)
end

-- The level has no start point for a second player: the pawn can spawn under the map and
-- fall forever, which also makes its split-screen camera render pure black. Bring it back.
local function keepPlayer2Near(p1, p2)
    if not (isLive(p1.pawn) and isLive(p2.pawn)) then return end
    local l1, l2 = locOf(p1.pawn), locOf(p2.pawn)
    if not (l1 and l2) then return end
    local below = (l1.Z or 0) - (l2.Z or 0)
    local far = distance2d(l1, l2)
    if below > CONFIG.dropLimit or far > CONFIG.maxDistance then
        local now = os.time()
        if now - lastReplace >= CONFIG.replaceCooldown then
            lastReplace = now
            log("player 2 is out of place (below %.0f, distance %.0f) - putting it back", below, far)
            placePlayer2(p1, p2, "out of place")
        end
    end
end

-- PawnClientRestart is what pushes the pawn's input component onto the controller's input
-- stack (and refreshes the view target). When the game spawns player 2's pawn outside its
-- normal flow it may never run, leaving player 2 controlling nothing.
local function ensureClientRestart(p2)
    if clientRestarted then return end
    if not (isLive(p2.pc) and isLive(p2.pawn)) then return end
    clientRestarted = true
    local ok, err = pcall(function() p2.pc:ClientRestart(p2.pawn) end)
    log("player 2 ClientRestart ok=%s %s", tostring(ok), ok and "" or tostring(err))
end

local function logPlayer2Input(p2)
    if loggedInput then return end
    if not (isLive(p2.pc) and isLive(p2.pawn)) then return end
    loggedInput = true
    local pid, input = nil, nil
    pcall(function() pid = p2.pc.Player.ControllerId end)
    pcall(function() input = p2.pc.PlayerInput end)
    log("player 2: controller id=%s input=%s pawn=%s", tostring(pid), fullName(input), fullName(p2.pawn))
end

local function createPlayer2(players, reason)
    local pc1 = players[1] and players[1].pc
    if not isLive(pc1) then return false end
    local now = os.time()
    if now - lastCreate < 5 then return false end
    lastCreate = now
    if isLive(gms) then
        gms.bUseSplitscreen = true
        gms.bOffsetPlayerGamepadIds = CONFIG.offsetGamepadIds == true
    end
    local before = localPlayerCount(players)
    local ok, res = pcall(function() return gs:CreatePlayer(pc1, CONFIG.pad2, true) end)
    local after = localPlayerCount(players)
    log("create player 2 (%s): ok=%s controller=%s local players %d -> %d (offset ids=%s)",
        reason, tostring(ok), ok and fullName(res) or tostring(res), before, after, tostring(CONFIG.offsetGamepadIds))
    return after > before
end

local function upkeep()
    if not CONFIG.enabled then return end
    ensureSingletons()
    if not isLive(gs) then return end

    local players = getPlayers()
    if #players == 0 then return end
    local pc1 = players[1].pc
    local world = nil
    pcall(function() world = pc1:GetWorld() end)
    if not isLive(world) then return end
    local worldName = fullName(world)

    if not isGameplayWorld(worldName) then
        if lastWorld ~= worldName then
            log("world -> %s (menu, co-op idle)", worldName)
            lastWorld = worldName
            placedForWorld = nil
            clientRestarted = false
        end
        if isLive(gms) then gms.bUseSplitscreen = false end
        return
    end

    if lastWorld ~= worldName then
        log("world -> %s (gameplay)", worldName)
        lastWorld = worldName
        placedForWorld = nil
        clientRestarted = false
    end
    if isLive(gms) then gms.bUseSplitscreen = true end

    if #players < 2 or localPlayerCount(players) < 2 then
        createPlayer2(players, "level upkeep")
        return
    end

    local p1, p2 = players[1], players[2]
    P2 = p2
    if not isMonoPawn(p2.pawn) then
        -- the game respawns pawns on checkpoint loads; give it a moment
        return
    end
    logPlayer2Input(p2)
    ensureClientRestart(p2)
    if placedForWorld ~= worldName then
        placedForWorld = worldName
        placePlayer2(p1, p2, "level start")
    end
    keepPlayer2Near(p1, p2)
end

LoopAsync(CONFIG.interval, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(upkeep)
        if not ok then log("upkeep error: %s", tostring(err)) end
    end)
end)

log("v0.5 loaded (player 2 = second Mono, Six stays AI, input bridge), co-op %s, dir %s", CONFIG.enabled and "on" or "off", MOD_DIR)



-- ---------------------------------------------------------------------------
-- Input bridge for player 2
--
-- On this build the game's input handling only serves the first local player: pad 2
-- events reach the second controller's PlayerInput, but none of the game's bound
-- actions ever run for player 2, so its Mono stays put. The bridge reads pad 2 itself
-- and drives the pawn through the same engine entry points the game uses.
-- ---------------------------------------------------------------------------

local BRIDGE = {
    enabled = true,
    deadzone = 0.25,
    -- degrees of camera rotation per second at full stick deflection
    lookSpeed = 180.0,
    -- how much of the stick is used for walking (engine caps it at 1.0 anyway)
    moveScale = 1.0,
}

local bridgeKeys = nil
local bridgeJumpWasDown = false
local bridgeDebugCount = 0
local bridgeLastSig = nil

local function resolveBridgeKeys()
    if bridgeKeys then return bridgeKeys end
    local ins = nil
    pcall(function() ins = StaticFindObject("/Script/Engine.Default__InputSettings") end)
    if not isLive(ins) then return nil end
    local wanted = {
        "Gamepad_LeftX", "Gamepad_LeftY", "Gamepad_RightX", "Gamepad_RightY",
        "Gamepad_FaceButton_Bottom", "Gamepad_FaceButton_Left",
    }
    local out, left = {}, #wanted
    local function scan(arr)
        if not isLive(arr) then return end
        local n = 0
        pcall(function() n = #arr end)
        if type(n) ~= "number" or n == 0 then n = 80 end
        for i = 1, math.min(n, 120) do
            local e = nil
            pcall(function() e = arr[i] end)
            if e ~= nil then
                local kn = nil
                pcall(function() kn = e.Key.KeyName:ToString() end)
                if kn then
                    for _, w in ipairs(wanted) do
                        if out[w] == nil and kn == w then
                            local k = nil
                            pcall(function() k = e.Key end)
                            if k ~= nil then out[w] = k; left = left - 1 end
                        end
                    end
                end
            end
        end
    end
    pcall(function() scan(ins.AxisMappings) end)
    pcall(function() scan(ins.ActionMappings) end)
    if left > 0 then return nil end
    bridgeKeys = out
    log("input bridge: resolved %d gamepad keys", #wanted)
    return bridgeKeys
end

-- analog value of a key for a player, or 0
local function keyValue(pc, name)
    local keys = resolveBridgeKeys()
    if not keys or not keys[name] then return 0.0 end
    local ok, v = pcall(function() return pc:GetInputAnalogKeyState(keys[name]) end)
    if ok and type(v) == "number" then return v end
    local ok2, down = pcall(function() return pc:IsInputKeyDown(keys[name]) end)
    if ok2 and down == true then return 1.0 end
    return 0.0
end

local function keyDown(pc, name)
    local keys = resolveBridgeKeys()
    if not keys or not keys[name] then return false end
    local ok, down = pcall(function() return pc:IsInputKeyDown(keys[name]) end)
    return ok and down == true
end

local function bridgeStep()
    if not (BRIDGE.enabled and CONFIG.enabled) then return end
    if not P2 then return end
    if not isLive(P2.pc) or not isLive(P2.pawn) then return end
    local pc, pawn = P2.pc, P2.pawn

    local mx = keyValue(pc, "Gamepad_LeftX")
    local my = keyValue(pc, "Gamepad_LeftY")
    if math.abs(mx) < BRIDGE.deadzone then mx = 0.0 end
    if math.abs(my) < BRIDGE.deadzone then my = 0.0 end

    if mx ~= 0.0 or my ~= 0.0 then
        local yaw = 0.0
        local ok, rot = pcall(function() return pc:GetControlRotation() end)
        if ok and type(rot) == "table" then yaw = rot.Yaw or 0.0 end
        local rad = math.rad(yaw)
        local fx, fy = math.cos(rad), math.sin(rad)
        local rx, ry = -math.sin(rad), math.cos(rad)
        local dir = {
            X = fx * my + rx * mx,
            Y = fy * my + ry * mx,
            Z = 0.0,
        }
        pcall(function() pawn:AddMovementInput(dir, BRIDGE.moveScale, false) end)
    end

    local lx = keyValue(pc, "Gamepad_RightX")
    local ly = keyValue(pc, "Gamepad_RightY")
    if math.abs(lx) < BRIDGE.deadzone then lx = 0.0 end
    if math.abs(ly) < BRIDGE.deadzone then ly = 0.0 end

    -- temporary diagnostics: log only changes, with the raw digital state next to it
    local sig = string.format("%.2f,%.2f,%.2f,%.2f", mx, my, lx, ly)
    if sig ~= bridgeLastSig then
        bridgeLastSig = sig
        log("bridge state: L=(%.2f,%.2f) R=(%.2f,%.2f) down(L)=%s down(A)=%s",
            mx, my, lx, ly,
            tostring(keyDown(pc, "Gamepad_LeftX")),
            tostring(keyDown(pc, "Gamepad_FaceButton_Bottom")))
    end
    if lx ~= 0.0 then
        local dt = CONFIG.bridgeInterval / 1000.0
        pcall(function() pawn:AddControllerYawInput(lx * BRIDGE.lookSpeed * dt) end)
    end
    if ly ~= 0.0 then
        local dt = CONFIG.bridgeInterval / 1000.0
        pcall(function() pawn:AddControllerPitchInput(ly * BRIDGE.lookSpeed * dt * 0.7) end)
    end

    local jump = keyDown(pc, "Gamepad_FaceButton_Bottom")
    if jump and not bridgeJumpWasDown then
        pcall(function() pawn:Jump() end)
    end
    bridgeJumpWasDown = jump
end

if BRIDGE.enabled then
    LoopAsync(CONFIG.bridgeInterval, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(bridgeStep)
            if not ok then log("bridge error: %s", tostring(err)) end
        end)
    end)
end
