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
    spawnSideOffset = 130.0,
    -- how often the upkeep runs, milliseconds
    interval = 2000,
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
local function placePlayer2(p1, p2)
    if not (isLive(p1.pawn) and isLive(p2.pawn)) then return false end
    local l1 = locOf(p1.pawn)
    if not l1 then return false end
    local right = nil
    pcall(function() right = p1.pawn:GetActorRightVector() end)
    if type(right) ~= "table" then return false end
    local spot = {
        X = l1.X + (right.X or 0) * CONFIG.spawnSideOffset,
        Y = l1.Y + (right.Y or 0) * CONFIG.spawnSideOffset,
        Z = l1.Z + 60.0,
    }
    local rot = nil
    pcall(function() rot = p1.pawn:K2_GetActorRotation() end)
    local ok = pcall(function()
        p2.pawn:K2_SetActorLocationAndRotation(spot, rot, false, {}, true)
    end)
    if ok then
        log("player 2 placed beside player 1 at %.0f %.0f %.0f", spot.X, spot.Y, spot.Z)
    end
    return ok
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
        gms.bOffsetPlayerGamepadIds = false
    end
    local before = localPlayerCount(players)
    local ok, res = pcall(function() return gs:CreatePlayer(pc1, CONFIG.pad2, true) end)
    local after = localPlayerCount(players)
    log("create player 2 (%s): ok=%s controller=%s local players %d -> %d",
        reason, tostring(ok), ok and fullName(res) or tostring(res), before, after)
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
        end
        if isLive(gms) then gms.bUseSplitscreen = false end
        return
    end

    if lastWorld ~= worldName then
        log("world -> %s (gameplay)", worldName)
        lastWorld = worldName
        placedForWorld = nil
    end
    if isLive(gms) then gms.bUseSplitscreen = true end

    if #players < 2 or localPlayerCount(players) < 2 then
        createPlayer2(players, "level upkeep")
        return
    end

    local p1, p2 = players[1], players[2]
    if not isMonoPawn(p2.pawn) then
        -- the game respawns pawns on checkpoint loads; give it a moment
        return
    end
    logPlayer2Input(p2)
    if placedForWorld ~= worldName then
        placedForWorld = worldName
        placePlayer2(p1, p2)
    end
end

LoopAsync(CONFIG.interval, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(upkeep)
        if not ok then log("upkeep error: %s", tostring(err)) end
    end)
end)

log("v0.3 loaded (player 2 = second Mono, Six stays AI), co-op %s, dir %s", CONFIG.enabled and "on" or "off", MOD_DIR)


