-- LN2Coop v0.6 - same-PC split-screen co-op for Little Nightmares II (Enhanced Edition)
--
-- Player 2 is a *second Mono*: the game's own game mode spawns a second BP_PlayerPawn
-- (same class as player 1) together with its own BP_PlayerPawnController and camera.
-- Six is never touched: she stays the game's AI companion, controlled by her own AI.
--
-- On this build the game's input stack only acts on player 1's controller: gamepad 2
-- events do reach player 2's PlayerInput (IsInputKeyDown / GetInputAnalogKeyState return
-- real values), but none of the game's bound actions run for player 2. The input bridge
-- below reads pad 2 itself and drives player 2's pawn directly.
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
    -- player 2 is put exactly on player 1: that is a known-good floor spot on this build.
    -- Stepping aside was tried and is not safe (a side spot can be outside the floor mesh
    -- or between rocks). The two Monos overlap until player 2 moves for the first time.
    --
    -- how often the upkeep runs, milliseconds
    interval = 1000,
    -- if player 2 ends up this far below / away from player 1 it is put back on them
    dropLimit = 1500.0,
    maxDistance = 3000.0,
    -- do not teleport more often than this, seconds
    replaceCooldown = 4,
    -- how often the player 2 input bridge runs, milliseconds
    bridgeInterval = 33,
    -- player 2 walking speed, units/s (the game's own MaxWalkSpeed is 210)
    moveSpeed = 210.0,
    -- camera rotation speed, degrees/s at full stick deflection
    lookSpeed = 150.0,
    -- vertical impulse used if Character::Jump() does not take
    jumpZ = 420.0,
    -- periodic state log, seconds
    diagInterval = 1.0,
    -- player 1 and player 2 must not block each other when they share a spawn point
    ignorePlayerCollision = true,
    -- optional file in the mod folder that overrides pad 2 for tests:
    --   "x,y" or "x,y,rx,ry,jump" (values -1..1), delete the file to use the real pad
    testDriveFile = "bridge_test.txt",
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

-- wall clock, seconds; on Windows Lua's os.clock() is the C runtime clock (wall time)
local function now()
    local ok, v = pcall(os.clock)
    return (ok and type(v) == "number") and v or 0
end

local function isLive(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local function fullName(o)
    local ok, n = pcall(function() return o and o:GetFullName() end)
    return ok and n or "<nil>"
end

local function shortName(o)
    local n = fullName(o)
    return n:match("([^%.%:/]+)$") or n
end

local function locOf(actor)
    local ok, v = pcall(function() return actor:K2_GetActorLocation() end)
    if ok and type(v) == "table" then return v end
    return nil
end

local function posText(p)
    if not p then return "nil" end
    return string.format("%.0f,%.0f,%.0f", p.X or 0, p.Y or 0, p.Z or 0)
end

local function distance2d(a, b)
    local dx, dy = (a.X or 0) - (b.X or 0), (a.Y or 0) - (b.Y or 0)
    return math.sqrt(dx * dx + dy * dy)
end

local function movementComp(pawn)
    local ok, mv = pcall(function() return pawn:GetMovementComponent() end)
    if ok and isLive(mv) then return mv end
    return nil
end

local function moveMode(mv)
    if not mv then return "?" end
    local ok, v = pcall(function() return mv.MovementMode end)
    return ok and tostring(v) or "?"
end

local function velocityOf(pawn)
    local ok, v = pcall(function() return pawn:GetVelocity() end)
    if ok and type(v) == "table" then return v end
    return { X = 0, Y = 0, Z = 0 }
end

local function speed2d(v)
    return math.sqrt((v.X or 0) ^ 2 + (v.Y or 0) ^ 2)
end

local gs, gms
local lastWorld = ""
local lastPlacedPawn = nil
local lastCreate = 0
local loggedInputFor = nil
local lastReplace = 0
local clientRestartedFor = nil
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

-- Two Monos spawned on the same spot would otherwise block each other forever: the
-- engine does not resolve character-character overlap on its own. The second pawn is
-- made to ignore the Pawn collision channel, so it can walk through player 1 (and Six);
-- everything else stays solid.
--
-- UPrimitiveComponent:MoveIgnoreActorAdd is not callable on this build (it returns a
-- TrivialObject / the call does nothing), so the collision response is changed instead.
local ECC_PAWN = 2
local ECR_IGNORE = 0

local function capsuleOf(pawn)
    local c = nil
    pcall(function() c = pawn.CapsuleComponent end)
    if isLive(c) then return c end
    return nil
end

local function ignoreCollisionBetween(p1, p2)
    if not CONFIG.ignorePlayerCollision then return end
    if not (isLive(p1.pawn) and isLive(p2.pawn)) then return end
    local c2 = capsuleOf(p2.pawn)
    if not c2 then
        log("player 2 collision: capsule not found")
        return
    end
    local before = nil
    pcall(function() before = c2:GetCollisionResponseToChannel(ECC_PAWN) end)
    local ok, err = pcall(function() c2:SetCollisionResponseToChannel(ECC_PAWN, ECR_IGNORE) end)
    local after = nil
    pcall(function() after = c2:GetCollisionResponseToChannel(ECC_PAWN) end)
    log("player 2 capsule vs Pawn channel: before=%s now=%s ok=%s%s",
        tostring(before), tostring(after), tostring(ok), ok and "" or (" err=" .. tostring(err)))
end

-- Put player 2 exactly on player 1. That spot is known to be on the floor mesh on this
-- build; a spot beside it can be outside the mesh and player 2 then falls for ever.
-- The engine keeps the old velocity across a teleport, so it is stopped explicitly.
local function placePlayer2(p1, p2, reason)
    if not (isLive(p1.pawn) and isLive(p2.pawn)) then return false end
    local l1 = locOf(p1.pawn)
    if not l1 then return false end
    local rot = nil
    pcall(function() rot = p1.pawn:K2_GetActorRotation() end)
    local before = locOf(p2.pawn)
    local ok, err = pcall(function()
        p2.pawn:K2_SetActorLocationAndRotation(l1, rot, false, {}, true)
    end)
    local after = locOf(p2.pawn)
    local dist = after and distance2d(after, l1) or -1
    local mv = movementComp(p2.pawn)
    if mv then
        pcall(function() mv:StopMovementImmediately() end)
        -- the pawn may have fallen out of the world; walking is the mode that lands it
        pcall(function() mv:SetMovementMode(1, 0) end)
    end
    ignoreCollisionBetween(p1, p2)
    log("player 2 placed on player 1 (%s): from %s target %s actual %s dist %.0f ok=%s%s",
        tostring(reason), posText(before), posText(l1), posText(after), dist, tostring(ok),
        (not ok) and (" err=" .. tostring(err)) or "")
    lastPlacedPawn = fullName(p2.pawn)
    return dist >= 0 and dist < 30
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
        local t = now()
        if t - lastReplace >= CONFIG.replaceCooldown then
            lastReplace = t
            log("player 2 is out of place (below %.0f, distance %.0f) - putting it back", below, far)
            placePlayer2(p1, p2, "out of place")
        end
    end
end

-- PawnClientRestart is what pushes the pawn's input component onto the controller's input
-- stack (and refreshes the view target). When the game spawns player 2's pawn outside its
-- normal flow it may never run, leaving player 2 controlling nothing.
local function ensureClientRestart(p2)
    if not (isLive(p2.pc) and isLive(p2.pawn)) then return end
    local id = fullName(p2.pawn)
    if clientRestartedFor == id then return end
    clientRestartedFor = id
    local ok, err = pcall(function() p2.pc:ClientRestart(p2.pawn) end)
    log("player 2 ClientRestart ok=%s %s", tostring(ok), ok and "" or tostring(err))
end

local function logPlayer2Input(p2)
    if not (isLive(p2.pc) and isLive(p2.pawn)) then return end
    local id = fullName(p2.pawn)
    if loggedInputFor == id then return end
    loggedInputFor = id
    local pid, input = nil, nil
    pcall(function() pid = p2.pc.Player.ControllerId end)
    pcall(function() input = p2.pc.PlayerInput end)
    log("player 2: controller id=%s input=%s pawn=%s", tostring(pid), fullName(input), shortName(p2.pawn))
end

local function createPlayer2(players, reason)
    local pc1 = players[1] and players[1].pc
    if not isLive(pc1) then return false end
    local t = now()
    if t - lastCreate < 5 then return false end
    lastCreate = t
    if isLive(gms) then
        gms.bUseSplitscreen = true
        gms.bOffsetPlayerGamepadIds = CONFIG.offsetGamepadIds == true
    end
    local before = localPlayerCount(players)
    local ok, res = pcall(function() return gs:CreatePlayer(pc1, CONFIG.pad2, true) end)
    local after = localPlayerCount(players)
    log("create player 2 (%s): ok=%s controller=%s local players %d -> %d (offset ids=%s)",
        reason, tostring(ok), ok and shortName(res) or tostring(res), before, after,
        tostring(CONFIG.offsetGamepadIds))
    if after > before then
        -- a brand new local player comes with a new pawn; force a fresh placement pass
        lastPlacedPawn = nil
        clientRestartedFor = nil
        loggedInputFor = nil
    end
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
            lastPlacedPawn = nil
            clientRestartedFor = nil
            loggedInputFor = nil
            P2 = nil
        end
        if isLive(gms) then gms.bUseSplitscreen = false end
        return
    end

    if lastWorld ~= worldName then
        log("world -> %s (gameplay)", worldName)
        lastWorld = worldName
        lastPlacedPawn = nil
        clientRestartedFor = nil
        loggedInputFor = nil
        P2 = nil
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

    local pawnName = fullName(p2.pawn)
    if lastPlacedPawn ~= pawnName then
        placePlayer2(p1, p2, "level start")
        return
    end

    keepPlayer2Near(p1, p2)
end

LoopAsync(CONFIG.interval, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(upkeep)
        if not ok then log("upkeep error: %s", tostring(err)) end
    end)
end)

log("v0.6 loaded (player 2 = second Mono, Six stays AI, input bridge), co-op %s, dir %s",
    CONFIG.enabled and "on" or "off", MOD_DIR)


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
    -- do not take over the camera until the stick is clearly moved
    lookDeadzone = 0.30,
    lastJumpAt = 0,
    jumpRequestedAt = 0,
    jumpZBefore = 0,
    jumpPrev = false,
    jumpProbeAt = nil,
    jumpProbeN = 0,
    testActive = false,
    testNextRead = 0,
    lastDiag = 0,
    lastSig = nil,
}

local bridgeKeys = nil

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
    local ok2, down = pcall(function() pc:IsInputKeyDown(keys[name]) end)
    if ok2 and down == true then return 1.0 end
    return 0.0
end

local function keyDown(pc, name)
    local keys = resolveBridgeKeys()
    if not keys or not keys[name] then return false end
    local ok, down = pcall(function() pc:IsInputKeyDown(keys[name]) end)
    return ok and down == true
end

-- Optional test drive: a small file in the mod folder replaces pad 2 with fixed values,
-- so the movement path can be checked without hands on the second gamepad.
local function readTestDrive()
    local t = now()
    if t < BRIDGE.testNextRead then return BRIDGE.testValues end
    BRIDGE.testNextRead = t + 0.2
    local path = MOD_DIR .. "/" .. CONFIG.testDriveFile
    local f = io.open(path, "r")
    if not f then
        if BRIDGE.testActive then
            log("test drive: off (file removed)")
            BRIDGE.testActive = false
            BRIDGE.testValues = nil
        end
        return nil
    end
    local s = f:read("*a") or ""
    f:close()
    local nums = {}
    for n in s:gmatch("-?%d*%.?%d+") do nums[#nums + 1] = tonumber(n) end
    if #nums < 2 then
        BRIDGE.testValues = nil
        return nil
    end
    local v = {
        mx = math.max(-1, math.min(1, nums[1] or 0)),
        my = math.max(-1, math.min(1, nums[2] or 0)),
        rx = math.max(-1, math.min(1, nums[3] or 0)),
        ry = math.max(-1, math.min(1, nums[4] or 0)),
        jump = (nums[5] or 0) ~= 0,
    }
    if not BRIDGE.testActive then
        BRIDGE.testActive = true
        log("test drive: on L=(%.2f,%.2f) R=(%.2f,%.2f) jump=%s", v.mx, v.my, v.rx, v.ry, tostring(v.jump))
    end
    BRIDGE.testValues = v
    return v
end

local function readSticks(pc)
    local t = readTestDrive()
    if t then return t.mx, t.my, t.rx, t.ry, t.jump, true end
    local mx = keyValue(pc, "Gamepad_LeftX")
    local my = keyValue(pc, "Gamepad_LeftY")
    local rx = keyValue(pc, "Gamepad_RightX")
    local ry = keyValue(pc, "Gamepad_RightY")
    if math.abs(mx) < BRIDGE.deadzone then mx = 0.0 end
    if math.abs(my) < BRIDGE.deadzone then my = 0.0 end
    if math.abs(rx) < BRIDGE.lookDeadzone then rx = 0.0 end
    if math.abs(ry) < BRIDGE.lookDeadzone then ry = 0.0 end
    return mx, my, rx, ry, keyDown(pc, "Gamepad_FaceButton_Bottom"), false
end

local function moveDirection(pc, mx, my)
    local yaw = 0.0
    local ok, rot = pcall(function() return pc:GetControlRotation() end)
    if ok and type(rot) == "table" then yaw = rot.Yaw or 0.0 end
    local rad = math.rad(yaw)
    local fx, fy = math.cos(rad), math.sin(rad)
    local rx, ry = -math.sin(rad), math.cos(rad)
    local dx = fx * my + rx * mx
    local dy = fy * my + ry * mx
    local len = math.sqrt(dx * dx + dy * dy)
    if len > 1.0 then dx, dy = dx / len, dy / len end
    return dx, dy, len
end

-- Drive the pawn through the character movement component. APawn::AddMovementInput does
-- not produce any acceleration for player 2 on this build (IsMoveInputIgnored is false,
-- but the game's input path still swallows it), so the horizontal velocity is written
-- directly. The movement component then does the usual thing: collision, slopes, gravity
-- and the walking animation all keep working.
local function drivePawn(pawn, dx, dy, dt)
    local mv = movementComp(pawn)
    if mv then
        local v = velocityOf(pawn)
        -- The movement component brakes between bridge ticks (it sees no input), so the
        -- measured speed is lower than the value written here. Compensate for that.
        local along = (v.X or 0) * dx + (v.Y or 0) * dy
        local speed = CONFIG.moveSpeed
        if along > 0 and along < speed then
            speed = math.min(speed * 1.5, speed + (speed - along))
        end
        local ok = pcall(function()
            mv.Velocity = { X = dx * speed, Y = dy * speed, Z = v.Z or 0 }
        end)
        if ok then return true end
    end
    -- no movement component (should not happen for a Mono): move the actor, swept
    local step = CONFIG.moveSpeed * dt
    local sx, sy = dx * step, dy * step
    local ok, moved = pcall(function()
        return pawn:AddActorWorldOffset({ X = sx, Y = sy, Z = 0 }, true, {}, false)
    end)
    if ok and moved == true then return true end
    local movedX, movedY = false, false
    if math.abs(sx) > 0.01 then
        local okx, mx = pcall(function()
            return pawn:AddActorWorldOffset({ X = sx, Y = 0, Z = 0 }, true, {}, false)
        end)
        movedX = okx and mx == true
    end
    if math.abs(sy) > 0.01 then
        local oky, my = pcall(function()
            return pawn:AddActorWorldOffset({ X = 0, Y = sy, Z = 0 }, true, {}, false)
        end)
        movedY = oky and my == true
    end
    return movedX or movedY
end

local function applyCamera(pc, rx, ry, dt)
    if rx == 0.0 and ry == 0.0 then return end
    local ok, rot = pcall(function() return pc:GetControlRotation() end)
    if not ok or type(rot) ~= "table" then return end
    local pitch = (rot.Pitch or 0.0) + ry * CONFIG.lookSpeed * dt * 0.7
    if pitch > 80.0 then pitch = 80.0 elseif pitch < -80.0 then pitch = -80.0 end
    local yaw = (rot.Yaw or 0.0) + rx * CONFIG.lookSpeed * dt
    local ok2, err = pcall(function()
        pc:SetControlRotation({ Pitch = pitch, Yaw = yaw, Roll = 0 })
    end)
    if not ok2 then log("camera: SetControlRotation failed: %s", tostring(err)) end
end

local function requestJump(pawn)
    local t = now()
    if t - BRIDGE.lastJumpAt < 0.25 then return end
    BRIDGE.lastJumpAt = t
    local z = velocityOf(pawn).Z or 0
    BRIDGE.jumpZBefore = z
    BRIDGE.jumpRequestedAt = t
    local ok, err = pcall(function() pawn:Jump() end)
    log("jump requested: ok=%s z=%.0f %s", tostring(ok), z, ok and "" or tostring(err))
end

local function bridgeDiag(pc, pawn, mx, my, rx, ry, isTest)
    local t = now()
    if t - BRIDGE.lastDiag < CONFIG.diagInterval then return end
    BRIDGE.lastDiag = t
    local p = locOf(pawn)
    local v = velocityOf(pawn)
    local mv = movementComp(pawn)
    local ignored, pawnIgnored = nil, nil
    pcall(function() ignored = pc:IsMoveInputIgnored() end)
    pcall(function() pawnIgnored = pawn:IsMoveInputIgnored() end)
    local yaw, pitch = 0, 0
    local crot = nil
    pcall(function() crot = pc:GetControlRotation() end)
    if type(crot) == "table" then yaw, pitch = crot.Yaw or 0, crot.Pitch or 0 end
    log("p2 state: pos=%s vel=%.0f,%.0f,%.0f speed=%.0f mode=%s moveIgnored=%s pawnIgnored=%s stick=%.2f,%.2f,%.2f,%.2f yaw=%.0f pitch=%.0f test=%s",
        posText(p), v.X or 0, v.Y or 0, v.Z or 0, speed2d(v),
        moveMode(mv), tostring(ignored), tostring(pawnIgnored),
        mx, my, rx, ry, yaw, pitch, tostring(isTest))
end

local function bridgeStep()
    if not (BRIDGE.enabled and CONFIG.enabled) then return end
    if not P2 then return end
    if not (isLive(P2.pc) and isLive(P2.pawn)) then return end
    local pc, pawn = P2.pc, P2.pawn
    local dt = CONFIG.bridgeInterval / 1000.0

    local mx, my, rx, ry, jump, isTest = readSticks(pc)
    applyCamera(pc, rx, ry, dt)

    local moving = (mx ~= 0.0 or my ~= 0.0)
    if moving then
        local dx, dy = moveDirection(pc, mx, my)
        drivePawn(pawn, dx, dy, dt)
    end

    if jump and not BRIDGE.jumpPrev then requestJump(pawn) end
    BRIDGE.jumpPrev = jump

    -- Character::Jump() does not take for player 2 (the game ignores p2's jump input),
    -- so put the pawn into falling mode and give it the vertical velocity directly.
    if BRIDGE.jumpRequestedAt > 0 and now() - BRIDGE.jumpRequestedAt >= 0.12 then
        local v = velocityOf(pawn)
        local vz = v.Z or 0
        if vz < 50.0 and BRIDGE.jumpZBefore < 50.0 then
            local mv = movementComp(pawn)
            local ok = false
            if mv then
                pcall(function() mv:SetMovementMode(3, 0) end)
                ok = pcall(function()
                    mv.Velocity = { X = v.X or 0, Y = v.Y or 0, Z = CONFIG.jumpZ }
                end)
            end
            if not ok then
                ok = pcall(function()
                    pawn:LaunchCharacter({ X = 0, Y = 0, Z = CONFIG.jumpZ }, false, true)
                end)
            end
            log("jump: Character::Jump did not lift the pawn (vz=%.0f) - forced falling+velocity ok=%s", vz, tostring(ok))
            BRIDGE.jumpProbeAt = now() + 0.15
            BRIDGE.jumpProbeN = 0
        end
        BRIDGE.jumpRequestedAt = 0
    end

    if BRIDGE.jumpProbeAt and now() >= BRIDGE.jumpProbeAt then
        local p = locOf(pawn)
        local v = velocityOf(pawn)
        log("jump probe %d: z=%.0f vz=%.0f mode=%s", BRIDGE.jumpProbeN + 1,
            p and p.Z or 0, v.Z or 0, moveMode(movementComp(pawn)))
        BRIDGE.jumpProbeN = BRIDGE.jumpProbeN + 1
        BRIDGE.jumpProbeAt = now() + 0.2
        if BRIDGE.jumpProbeN >= 4 then BRIDGE.jumpProbeAt = nil end
    end

    local sig = string.format("%.2f,%.2f,%.2f,%.2f", mx, my, rx, ry)
    if sig ~= BRIDGE.lastSig then
        BRIDGE.lastSig = sig
        log("bridge state: L=(%.2f,%.2f) R=(%.2f,%.2f) down(L)=%s down(A)=%s test=%s",
            mx, my, rx, ry,
            tostring(keyDown(pc, "Gamepad_LeftX")),
            tostring(keyDown(pc, "Gamepad_FaceButton_Bottom")),
            tostring(isTest))
    end

    bridgeDiag(pc, pawn, mx, my, rx, ry, isTest)
end

if BRIDGE.enabled then
    LoopAsync(CONFIG.bridgeInterval, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(bridgeStep)
            if not ok then log("bridge error: %s", tostring(err)) end
        end)
    end)
end
