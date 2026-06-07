--[[
    AV PIRATE DYNASTY RUNTIME
    VERSION: V1.0

    Standalone Pirate Dynasty mode:
    - Loaded directly by BOOTSTRAP.lua when Pirate Dynasty runtime is detected.
    - Does not require Brain, Eyes, StageRouter, MacroReader, TeamEquip, SettingsApplier, or Goal controller.
    - Reads Dynasty Level locally, runs pre-match setup, then starts the preserved Pirate Dynasty combat script.

    Commands:
    - _G.AVPirateDynastyStart()
    - _G.AVPirateDynastyStop()
    - _G.AVPirateDynastyStatus()
    - _G.AVPirateDynastySnapshot()
    - _G.AVStop()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local VERSION = "AV-PIRATE-DYNASTY-RUNTIME V1.0"
local PIRATE_PLACE_ID = 16277809958

local DEFAULT_CONFIG = {
    Enabled = true,
    AutoStart = true,
    CharacterId = "ElasticCaptainPirate",
    CharacterDisplayName = "Elastic Captain (Cog 4th)",
    RequiredRunes = { "CARVE THROUGH", "STRIKER'S EDGE III" },
    EquipRunes = { "Rune8", "Rune10" },
    DifficultyWhenRunesReady = "Hard",
    DifficultyWhenRunesMissing = "Easy",
    TargetModifier = "Floodgates",
    RemoteDelaySeconds = 0.5,
    WaitForRuntimeSeconds = 20,
    WaitForRunesSeconds = 6,
    WaitForVoteSeconds = 20,
    StartCombatAfterMatch = true,
    QuietCombatDumps = true,
}

local function cloneTable(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = cloneTable(child) end
    return result
end

local function mergeInto(base, override)
    if type(override) ~= "table" then return base end
    for key, value in pairs(override) do
        if type(value) == "table" and type(base[key]) == "table" then
            mergeInto(base[key], value)
        else
            base[key] = cloneTable(value)
        end
    end
    return base
end

local config = cloneTable(DEFAULT_CONFIG)
if type(_G.AVPirateDynastyConfig) == "table" then mergeInto(config, _G.AVPirateDynastyConfig) end

local previousAVStop = type(_G.AVStop) == "function" and _G.AVStop or nil
local state = {
    token = nil,
    running = false,
    phase = "idle",
    reason = "loaded",
    runtimeSource = "<none>",
    dynastyLevel = nil,
    dynastyLevelText = "<missing>",
    runesReady = false,
    lastDifficulty = "<none>",
    combatStarted = false,
    startedAt = nil,
    stoppedAt = nil,
}

local function log(message) print("[PirateRuntime] " .. tostring(message)) end
local function warnLog(message) warn("[PirateRuntime] " .. tostring(message)) end
local function isCurrent(token) return state.running and state.token == token end

local function waitUntil(token, predicate, timeoutSeconds, intervalSeconds)
    local deadline = os.clock() + (timeoutSeconds or 5)
    local interval = intervalSeconds or 0.2
    while isCurrent(token) and os.clock() < deadline do
        local ok, value, extra = pcall(predicate)
        if ok and value then return value, extra end
        task.wait(interval)
    end
    return nil
end

local function getPlayerGui()
    return player and player:FindFirstChild("PlayerGui")
end

local function getHud()
    local playerGui = getPlayerGui()
    return playerGui and playerGui:FindFirstChild("PirateDynastyHUD")
end

local function detectPirateRuntime()
    if game.PlaceId == PIRATE_PLACE_ID then return true, "PirateDynasty PlaceId" end
    if getHud() then return true, "PlayerGui.PirateDynastyHUD" end
    local entities = Workspace:FindFirstChild("Entities")
    if entities and entities:FindFirstChild("PirateDynasty") then return true, "Workspace.Entities.PirateDynasty" end
    return false, "not pirate dynasty"
end

local function isCombatRuntimeLoaded()
    local entities = Workspace:FindFirstChild("Entities")
    return entities and entities:FindFirstChild("PirateDynasty") ~= nil
end

local function normalize(text)
    return string.upper((tostring(text or "")):match("^%s*(.-)%s*$"))
end

local function parseDynastyLevel(text)
    local value = tostring(text or ""):match("[Dd]ynasty%s+[Ll]evel%s+(%d+)")
        or tostring(text or ""):match("(%d+)%s*/%s*%d+")
        or tostring(text or ""):match("(%d+)")
    return value and tonumber(value) or nil
end

local function readDynastyLevel()
    local hud = getHud()
    if not hud then
        state.dynastyLevel = nil
        state.dynastyLevelText = "<hud missing>"
        return nil
    end
    for _, descendant in ipairs(hud:GetDescendants()) do
        if descendant:IsA("TextLabel") then
            local text = descendant.Text or ""
            if string.find(string.lower(text), "dynasty level", 1, true) then
                state.dynastyLevelText = text
                state.dynastyLevel = parseDynastyLevel(text)
                return state.dynastyLevel
            end
        end
    end
    state.dynastyLevel = nil
    state.dynastyLevelText = "<missing>"
    return nil
end

local function getInterfaceEvent()
    local networking = ReplicatedStorage:FindFirstChild("Networking")
    return networking and networking:FindFirstChild("InterfaceEvent")
end

local function fireInterface(payload)
    local event = getInterfaceEvent()
    if not event then return false, "ReplicatedStorage.Networking.InterfaceEvent missing" end
    event:FireServer("PirateDynastySelect", payload)
    return true
end

local function getSlotsRow()
    local hud = getHud()
    local export = hud and hud:FindFirstChild("Export")
    local rightSide = export and export:FindFirstChild("RightSide")
    local container = rightSide and rightSide:FindFirstChild("Container")
    local frame = container and container:FindFirstChild("Frame")
    local runesContainer = frame and frame:FindFirstChild("RunesContainer")
    local panel = runesContainer and runesContainer:FindFirstChild("RunesPanel")
    return panel and panel:FindFirstChild("SlotsRow")
end

local function readRunes()
    local slotsRow = getSlotsRow()
    if not slotsRow then return nil end
    local values = {}
    for _, child in ipairs(slotsRow:GetChildren()) do
        if child.Name == "Stat" then
            local desc = child:FindFirstChild("PassiveDescription")
            if desc and desc:IsA("TextLabel") and desc.Text ~= "" then
                table.insert(values, desc.Text)
            else
                for _, descendant in ipairs(child:GetDescendants()) do
                    if descendant:IsA("TextLabel") and descendant.Text ~= "" then table.insert(values, descendant.Text) end
                end
            end
        end
    end
    if #values == 0 then return nil end
    return values
end

local function hasRequiredRunes(runes)
    if type(runes) ~= "table" then return false end
    local required = config.RequiredRunes or {}
    local found = {}
    for _, runeText in ipairs(runes) do
        local normalizedRune = normalize(runeText)
        for _, requiredText in ipairs(required) do
            if string.find(normalizedRune, normalize(requiredText), 1, true) then found[requiredText] = true end
        end
    end
    for _, requiredText in ipairs(required) do if not found[requiredText] then return false end end
    return #required > 0
end

local function getVoteOptionsRow()
    local hud = getHud()
    local vote = hud and hud:FindFirstChild("SeaConditionsVote")
    return vote and vote:FindFirstChild("OptionsRow")
end

local function modifierVisible(target)
    local optionsRow = getVoteOptionsRow()
    if not optionsRow then return false end
    local wanted = string.lower(tostring(target or ""))
    for _, descendant in ipairs(optionsRow:GetDescendants()) do
        if descendant:IsA("TextLabel") and descendant.Name == "Title" and descendant.Visible then
            if string.find(string.lower(descendant.Text or ""), wanted, 1, true) then return true end
        end
    end
    return false
end

local function stopCombatOnly()
    _G.PirateDynastyAutoFarm = false
    _G.PirateDynastyAutoFarmV11 = false
    _G.PirateDynastyAutoFarmV12 = false
    _G.PirateDynastyAutoFarmV13 = false
    _G.PirateDynastyAutoFarmV14 = false
    _G.PirateDynastyRunnerTokenV14 = {}
    state.combatStarted = false
end

local function startCombatInternal()--[[
    SCRIPT TYPE: MAIN SCRIPT - SAFE EFFECT CLEANUP
    VERSION: MAIN-SCRIPT V1.8

    Changes since MAIN-SCRIPT V1.7:
    - Removes position gating for boss attacks entirely. The attack worker no longer
      requires isAtCombatPosition to return true before firing at a boss. If the boss
      is a valid target and the attack cooldown has elapsed, the attack fires immediately.
    - Removes boss spawn hold (BossSpawnHoldSeconds) for bosses that are already within
      attack range when first detected. Hold only applies if distance > MaxBossTravelDistance / 4.
    - Simplifies isValidEnemy for bosses: only checks alive + HP > 0 + within MaxBossTravelDistance
      or within grace period. Removes the validateBossTravelTarget playable-Y check from the
      hot path since bosses can teleport above the map briefly during phase transitions.
    - Removes getSafeBossDestination dependency from attack worker; attack direction is computed
      directly from anchorPart.Position so movement state never blocks attacks.

    Changes since MAIN-SCRIPT V1.6:
    - Fixes boss target re-locking after teleport: after dropping a boss, findBestEnemy now
      uses getBossAnchorPart for distance scoring so bosses are found even when HumanoidRootPart
      is nil mid-phase-transition.
    - Fixes boss-spawn-hold blocking attack when boss is already close: beginBossHoldIfNeeded
      now skips the hold if the boss is already within BossHoverHeight * 3 of the character.
    - Fixes getSafeDestination failing for boss destinations: boss movement now calls a dedicated
      getSafeBossDestination that skips the vertical-gap check (same bypass as isValidEnemy).
    - Fixes moveTo cancelling mid-tween for boss because validateTravelTarget Y-gap fails while
      the boss is above the character: moveTo now accepts an optional isBoss flag and skips the
      Y-gap validation step when chasing a boss.
    - Adds BossReLockGraceSeconds (default 2): after a boss teleports and isValidEnemy drops it,
      the main loop keeps retrying findBestEnemy for up to this many seconds before going IDLE.

    Changes since MAIN-SCRIPT V1.4:
    - Fixes boss target being dropped: validateTravelTarget (MAX_TARGET_VERTICAL_GAP=34) is no
      longer used for boss enemies. Bosses use validateBossTravelTarget which skips the Y-gap check.
    - Adds getBossAnchorPart: walks model descendants to find the real anchor BasePart when
      HumanoidRootPart is swapped during a phase transition.
    - Fixes grace period always resetting: bossOutOfRangeUntil is set only once when the boss
      first goes out of range; cleared when the boss returns in range.
    - Fixes potion interrupting boss fight: runPowerupState skips non-health powerups while a boss
      is the active target. Health potions are still collected when HP is below threshold.
    - Adds MaxBossTravelDistance (default 700) for boss-specific distance limit.
    - Adds BossOutOfRangeGraceSeconds (default 3) grace period before dropping an out-of-range boss.
    - Adds an independent cosmetic-effect cleanup worker without changing combat or movement flow.
    - Deletes only effect components inside Workspace.Map and Workspace.Visuals.
    - Always protects PirateDynastyPowerups and never deletes Models, Folders, or BaseParts.

    This is a damage-avoidance test, not server-side invincibility.

    Commands:
    - _G.PirateDynastyAutoFarmV14 = true / false
    - _G.PirateDynastyDebugV14 = true / false
    - _G.PirateDynastyAttackDumpV14 = true / false
    - _G.PirateDynastyTargetLossDumpV14 = true / false
    - _G.PirateDynastySaveRuntimeLogV14()
    - _G.PirateDynastyConfigV14.EnableEffectCleanup = true / false
    - _G.PirateDynastyCleanupEffectsV14()
    - _G.PirateDynastyConfigV14.MeleeHoverHeight = 18
    - _G.PirateDynastyConfigV14.RangedHoverHeight = 24
    - _G.PirateDynastyConfigV14.BossHoverHeight = 24
    - _G.PirateDynastyConfigV14.MaxBossTravelDistance = 700
    - _G.PirateDynastyConfigV14.BossOutOfRangeGraceSeconds = 3

    Recommended config ranges:
    - HealthPickupThreshold = 70
      Range: 60-95. Higher values collect Health sooner but interrupt farming more often.
    - MeleeHoverHeight = 18
      Range: 14-24. Higher values avoid melee damage better. Too high may reduce hit reliability.
    - RangedHoverHeight = 24
      Range: 20-32. Higher values can avoid some ranged attacks. Too high may reduce hit reliability.
    - BossHoverHeight = 24
      Range: 20-32. Raise this if boss attacks still hit. Lower it if Basic attacks miss.
    - BossSpawnHoldSeconds = 3
      Range: 2-5. The character stays still before approaching each newly spawned boss.
    - NormalAttackCooldown = 0.055
      Range: 0.04-0.10. Lower values send Basic attacks faster but may hit server rate limits.
    - BossAttackCooldown = 0.04
      Range: 0.03-0.08. Lower values attack bosses faster but may hit server rate limits.
    - MainTickSeconds = 0.045
      Range: 0.035-0.08. Lower values react faster but increase client workload.
    - MaxEnemyTravelDistance = 80
      Range: 60-250. Applies to normal/ranged enemies only. Does not apply to bosses.
      Keep this value higher than the largest hover height.
    - MaxBossTravelDistance = 700
      Range: 200-1200. Distance limit used exclusively for boss enemies.
    - BossOutOfRangeGraceSeconds = 3
      Range: 1-8. Seconds the boss target stays valid after exceeding MaxBossTravelDistance.
    - BossReLockGraceSeconds = 2
      Range: 1-5. After losing a boss target (teleport/phase), keep retrying findBestEnemy for
      this many seconds before falling through to IDLE. Prevents the noTarget gap in ATTACK-DUMP.
    - CombatAttackTolerance = 10
      Range: 6-16. Used for melee enemies. Higher values keep attacking while the enemy moves.
    - RangedAttackTolerance = 30
      Range: 20-40. Long-range AoE characters can keep attacking while repositioning near ranged enemies.
    - BossAttackTolerance = 40
      Range: 30-50. Long-range AoE characters can keep attacking while tracking a moving boss.
    - ShortSnapDistance = 14
      Range: 8-20. Movement inside this distance uses a safe snap instead of a tween.
    - AttackWorkerTickSeconds = 0.015
      Range: 0.01-0.03. Lower values check attack cooldowns more often but increase client workload.
    - AttackDumpIntervalSeconds = 1
      Range: 0.5-5. Prints attack-worker counters periodically when PirateDynastyAttackDumpV14 is true.
    - EnableEffectCleanup = true
      Set false if a required visual marker disappears. Combat and movement continue normally.
    - CleanupMapEffects = true
      Deletes cosmetic effect components inside Workspace.Map only. Map parts are never deleted.
    - CleanupVisualEffects = true
      Deletes cosmetic effect components inside Workspace.Visuals except PirateDynastyPowerups.
    - CleanupIntervalSeconds = 0.75
      Range: 0.25-2. Lower values clear skill effects sooner but increase client workload.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local interfaceEvent = ReplicatedStorage:WaitForChild("Networking"):WaitForChild("InterfaceEvent")

local VERSION = "MAIN-SCRIPT V1.8"
local MOVE_SPEED = 200
local MOVE_TIMEOUT_PADDING = 1.5
local POTION_RESCAN_SECONDS = 0.35
local ENEMY_RESCAN_SECONDS = 0.16
local REPOSITION_DISTANCE = 2.5
local DEFAULT_MAX_ENEMY_TRAVEL_DISTANCE = 80
local DEFAULT_MAX_BOSS_TRAVEL_DISTANCE = 700
local DEFAULT_BOSS_OUT_OF_RANGE_GRACE_SECONDS = 3
local DEFAULT_BOSS_RELOCK_GRACE_SECONDS = 2
local MAX_TARGET_VERTICAL_GAP = 34
local MAP_Y_MARGIN_BELOW = 15
local MAP_Y_MARGIN_ABOVE = 36
local COSMETIC_EFFECT_CLASSES = {
    ParticleEmitter = true,
    Trail = true,
    Beam = true,
    Smoke = true,
    Fire = true,
    Sparkles = true,
    Explosion = true,
    Highlight = true,
}

local state = "BOOT"
local lastAttackAt = 0
local lastPotionScanAt = 0
local lastEnemyScanAt = 0
local cachedPotionTarget = nil
local cachedEnemyTarget = nil
local activeCombatTarget = nil
local runnerToken = {}
local bossHoldUntil = 0
local bossOutOfRangeUntil = 0
local bossReLockUntil = 0
local heldBosses = setmetatable({}, { __mode = "k" })
local hasUnheldBossSpawned = nil
local lastTargetLossSignature = nil
local lastTargetLossAt = 0
local runtimeLogLines = {}
local runtimeLogFilename = "anime_vanguards_MAIN-SCRIPT_V1_8_RUNTIME_" .. tostring(os.time()) .. ".txt"
local MAX_RUNTIME_LOG_LINES = 1800
local attackDumpStats = {
    windowStartedAt = os.clock(),
    ticks = 0,
    noTarget = 0,
    bossHold = 0,
    unheldBoss = 0,
    outsideTolerance = 0,
    ready = 0,
    invalidEnemy = 0,
    cooldownBlocked = 0,
    remoteSent = 0,
    remoteFailed = 0,
}

-- Pause prior main-script loops if they are still alive in this session.
_G.PirateDynastyAutoFarm = false
_G.PirateDynastyAutoFarmV11 = false
_G.PirateDynastyAutoFarmV12 = false
_G.PirateDynastyAutoFarmV13 = false
_G.PirateDynastyAutoFarmV14 = true
_G.PirateDynastyDebugV14 = _G.PirateDynastyDebugV14 == true
_G.PirateDynastyAttackDumpV14 = _G.PirateDynastyAttackDumpV14 ~= false
_G.PirateDynastyTargetLossDumpV14 = _G.PirateDynastyTargetLossDumpV14 ~= false
_G.PirateDynastyRunnerTokenV14 = runnerToken
_G.PirateDynastyConfigV14 = _G.PirateDynastyConfigV14 or {
    HealthPickupThreshold = 70,
    MeleeHoverHeight = 18,
    RangedHoverHeight = 24,
    BossHoverHeight = 24,
    BossSpawnHoldSeconds = 3,
    NormalAttackCooldown = 0.055,
    BossAttackCooldown = 0.04,
    MainTickSeconds = 0.045,
    MaxEnemyTravelDistance = DEFAULT_MAX_ENEMY_TRAVEL_DISTANCE,
    MaxBossTravelDistance = DEFAULT_MAX_BOSS_TRAVEL_DISTANCE,
    BossOutOfRangeGraceSeconds = DEFAULT_BOSS_OUT_OF_RANGE_GRACE_SECONDS,
    BossReLockGraceSeconds = DEFAULT_BOSS_RELOCK_GRACE_SECONDS,
    CombatAttackTolerance = 10,
    RangedAttackTolerance = 30,
    BossAttackTolerance = 40,
    ShortSnapDistance = 14,
    AttackWorkerTickSeconds = 0.015,
    AttackDumpIntervalSeconds = 1,
    EnableEffectCleanup = true,
    CleanupMapEffects = true,
    CleanupVisualEffects = true,
    CleanupIntervalSeconds = 0.75,
}

local function debugLog(message)
    if _G.PirateDynastyDebugV14 then
        print("[" .. VERSION .. "][" .. state .. "] " .. message)
    end
end

local function saveRuntimeLog()
    if typeof(writefile) ~= "function" then
        return false
    end

    local success, errorMessage = pcall(function()
        writefile(runtimeLogFilename, table.concat(runtimeLogLines, "\n"))
    end)

    if not success then
        warn("[" .. VERSION .. "] failed to write runtime log: " .. tostring(errorMessage))
    end

    return success
end

local function addRuntimeLog(category, message)
    local line = string.format(
        "[%s][%s] %s",
        os.date("!%Y-%m-%dT%H:%M:%SZ"),
        tostring(category),
        tostring(message)
    )

    table.insert(runtimeLogLines, line)

    if #runtimeLogLines > MAX_RUNTIME_LOG_LINES then
        table.remove(runtimeLogLines, 1)
    end

    saveRuntimeLog()
    return line
end

_G.PirateDynastySaveRuntimeLogV14 = saveRuntimeLog

local function setState(nextState)
    if state ~= nextState then
        state = nextState
        debugLog("state changed")
    end
end

local function getRootPart()
    local character = player.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function isFiniteNumber(value)
    return value == value and value > -math.huge and value < math.huge
end

local function isFiniteVector3(position)
    return isFiniteNumber(position.X)
        and isFiniteNumber(position.Y)
        and isFiniteNumber(position.Z)
end

local function getPlayableYBounds()
    local map = workspace:FindFirstChild("Map")
    local rootPart = getRootPart()
    local fallbackY = rootPart and rootPart.Position.Y or 0
    local minimumY = map and tonumber(map:GetAttribute("MinHeight")) or (fallbackY - 20)
    local maximumY = map and tonumber(map:GetAttribute("MaxHeight")) or (fallbackY + 20)

    return minimumY - MAP_Y_MARGIN_BELOW, maximumY + MAP_Y_MARGIN_ABOVE
end

local function isPositionWithinPlayableY(position)
    if not isFiniteVector3(position) then
        return false
    end

    local minimumY, maximumY = getPlayableYBounds()
    return position.Y >= minimumY and position.Y <= maximumY
end

local function isInstanceAlive(instance)
    return instance and instance.Parent ~= nil
end

local function validateTravelTarget(targetPart, originRootPart)
    if not originRootPart or not isInstanceAlive(targetPart) or not targetPart:IsA("BasePart") then
        return false, "invalid-target"
    end

    if not isPositionWithinPlayableY(targetPart.Position) then
        return false, "target-outside-playable-y"
    end

    local delta = targetPart.Position - originRootPart.Position

    if not isFiniteNumber(delta.Magnitude) then
        return false, "invalid-distance"
    end

    if math.abs(delta.Y) > MAX_TARGET_VERTICAL_GAP then
        return false, "vertical-gap-too-large"
    end

    return true, "ok"
end

local function getSafeDestination(targetPart, offset, originRootPart)
    local isValid, reason = validateTravelTarget(targetPart, originRootPart)

    if not isValid then
        return nil, reason
    end

    local destination = CFrame.new(targetPart.Position + offset)

    if not isPositionWithinPlayableY(destination.Position) then
        return nil, "destination-outside-playable-y"
    end

    return destination, "ok"
end

-- For bosses only: skips the vertical-gap check so phase transitions do not drop the target.
local function validateBossTravelTarget(targetPart, originRootPart)
    if not originRootPart or not isInstanceAlive(targetPart) or not targetPart:IsA("BasePart") then
        return false, "invalid-target"
    end

    if not isPositionWithinPlayableY(targetPart.Position) then
        return false, "target-outside-playable-y"
    end

    local delta = targetPart.Position - originRootPart.Position

    if not isFiniteNumber(delta.Magnitude) then
        return false, "invalid-distance"
    end

    return true, "ok"
end

-- Returns the best available BasePart for a boss model.
-- Tries HumanoidRootPart first, then PrimaryPart, then any descendant BasePart.
local function getBossAnchorPart(boss)
    if not boss then
        return nil
    end

    local hrp = boss:FindFirstChild("HumanoidRootPart")
    if hrp and hrp:IsA("BasePart") then
        return hrp
    end

    if boss.PrimaryPart then
        return boss.PrimaryPart
    end

    for _, desc in ipairs(boss:GetDescendants()) do
        if desc:IsA("BasePart") then
            return desc
        end
    end

    return nil
end

-- Boss-specific destination: skips Y-gap so hovering above a boss does not
-- cancel the tween or make destination invalid during a phase transition.
local function getSafeBossDestination(targetPart, offset, originRootPart)
    local valid, reason = validateBossTravelTarget(targetPart, originRootPart)

    if not valid then
        return nil, reason
    end

    local destination = CFrame.new(targetPart.Position + offset)

    if not isPositionWithinPlayableY(destination.Position) then
        return nil, "destination-outside-playable-y"
    end

    return destination, "ok"
end

local function moveTo(targetPart, offset, isBoss)
    local rootPart = getRootPart()
    local destination, validationReason = getSafeDestination(targetPart, offset, rootPart)

    if not rootPart or not destination then
        debugLog("move rejected: " .. tostring(validationReason))
        return false, validationReason or "invalid-target"
    end

    local distance = (rootPart.Position - destination.Position).Magnitude

    if distance <= REPOSITION_DISTANCE then
        rootPart.CFrame = destination
        return true, "already-close"
    end

    local duration = distance / MOVE_SPEED
    local tween = TweenService:Create(
        rootPart,
        TweenInfo.new(duration, Enum.EasingStyle.Linear),
        { CFrame = destination }
    )
    local finished = false
    local playbackState = nil
    local connection

    connection = tween.Completed:Connect(function(result)
        playbackState = result
        finished = true
    end)

    tween:Play()

    local deadline = os.clock() + duration + MOVE_TIMEOUT_PADDING

    while not finished and os.clock() < deadline do
        local currentRootPart = getRootPart()
        local isTargetValid = currentRootPart and (
            isBoss
                and validateBossTravelTarget(targetPart, currentRootPart)
                or validateTravelTarget(targetPart, currentRootPart)
        )

        if not _G.PirateDynastyAutoFarmV14
            or _G.PirateDynastyRunnerTokenV14 ~= runnerToken
            or not currentRootPart
            or currentRootPart ~= rootPart
            or not isPositionWithinPlayableY(currentRootPart.Position)
            or not isTargetValid
            or (hasUnheldBossSpawned and hasUnheldBossSpawned())
        then
            tween:Cancel()
            break
        end

        task.wait(0.05)
    end

    if connection then
        connection:Disconnect()
    end

    if not finished then
        tween:Cancel()
        return false, "interrupted-or-timeout"
    end

    return playbackState == Enum.PlaybackState.Completed, tostring(playbackState)
end

local function getHealthPercentage()
    local success, result = pcall(function()
        local healthUi = player.PlayerGui.PirateDynastyHUD.Frame.HudStack.Bottom.RightSide.HealthValue
        local cleanText = string.gsub(healthUi.Text, ",", "")
        local currentText, maxText = string.match(cleanText, "(%d+)%s*/%s*(%d+)")
        local currentHealth = tonumber(currentText)
        local maxHealth = tonumber(maxText)

        if currentHealth and maxHealth and maxHealth > 0 then
            return (currentHealth / maxHealth) * 100
        end

        return 100
    end)

    return success and result or 100
end

local function getInstancePath(instance)
    if not instance then
        return "nil"
    end

    local success, result = pcall(function()
        return instance:GetFullName()
    end)

    return success and result or tostring(instance)
end

local function getCharacterHealthText()
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")

    if not humanoid then
        return "n/a"
    end

    return string.format("%.1f/%.1f", humanoid.Health, humanoid.MaxHealth)
end

local function clearActiveCombatTarget(reason, enemy)
    local previousTarget = activeCombatTarget
    activeCombatTarget = nil

    if not _G.PirateDynastyTargetLossDumpV14 then
        return
    end

    local target = enemy or previousTarget
    local signature = tostring(reason) .. "|" .. getInstancePath(target)
    local now = os.clock()

    if not target or (signature == lastTargetLossSignature and now - lastTargetLossAt < 0.75) then
        return
    end

    lastTargetLossSignature = signature
    lastTargetLossAt = now

    local rootPart = getRootPart()
    local enemyRoot = target and target:FindFirstChild("HumanoidRootPart")
    local health = target and target:GetAttribute("Health")
    local distance = rootPart and enemyRoot
        and string.format("%.1f", (rootPart.Position - enemyRoot.Position).Magnitude)
        or "n/a"

    local message = string.format(
        "[%s][TARGET-LOSS] state=%s reason=%s target=%s enemyHP=%s distance=%s characterHP=%s",
        VERSION,
        state,
        tostring(reason),
        getInstancePath(target),
        tostring(health),
        distance,
        getCharacterHealthText()
    )

    print(message)
    addRuntimeLog("TARGET-LOSS", message)
end

local function findFirstBasePart(instance)
    if not instance then
        return nil
    end

    if instance:IsA("BasePart") then
        return instance
    end

    if instance:IsA("Model") and instance.PrimaryPart then
        return instance.PrimaryPart
    end

    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant:IsA("BasePart") then
            return descendant
        end
    end

    return nil
end

local function getPowerupFolder()
    local visuals = workspace:FindFirstChild("Visuals")
    return visuals and visuals:FindFirstChild("PirateDynastyPowerups")
end

local function getConfigBoolean(name, fallback)
    local value = _G.PirateDynastyConfigV14[name]

    if value == nil then
        return fallback
    end

    return value == true
end

local function isInsideProtectedCleanupTree(instance)
    local protectedRoots = {
        player.Character,
        workspace:FindFirstChild("Entities"),
        workspace:FindFirstChild("PirateDynastyCaptureCircle"),
        getPowerupFolder(),
    }

    for _, protectedRoot in pairs(protectedRoots) do
        if protectedRoot
            and (instance == protectedRoot or instance:IsDescendantOf(protectedRoot))
        then
            return true
        end
    end

    return false
end

local function cleanupEffectRoot(root)
    if not root then
        return 0
    end

    local removedCount = 0

    for _, descendant in ipairs(root:GetDescendants()) do
        if COSMETIC_EFFECT_CLASSES[descendant.ClassName]
            and not isInsideProtectedCleanupTree(descendant)
        then
            local success = pcall(function()
                descendant:Destroy()
            end)

            if success then
                removedCount += 1
            end
        end
    end

    return removedCount
end

local function cleanupCosmeticEffects()
    if not getConfigBoolean("EnableEffectCleanup", true) then
        return 0
    end

    local removedCount = 0

    if getConfigBoolean("CleanupMapEffects", true) then
        removedCount += cleanupEffectRoot(workspace:FindFirstChild("Map"))
    end

    if getConfigBoolean("CleanupVisualEffects", true) then
        removedCount += cleanupEffectRoot(workspace:FindFirstChild("Visuals"))
    end

    if removedCount > 0 then
        debugLog("cleaned cosmetic effects: " .. tostring(removedCount))
    end

    return removedCount
end

_G.PirateDynastyCleanupEffectsV14 = cleanupCosmeticEffects

local function scorePowerup(powerup, healthPercentage)
    local name = string.lower(powerup.Name)

    if string.find(name, "health", 1, true) then
        local threshold = tonumber(_G.PirateDynastyConfigV14.HealthPickupThreshold) or 70
        return healthPercentage < threshold and 350 or nil
    end

    if string.find(name, "damage", 1, true) then
        return 220
    end

    if string.find(name, "speed", 1, true) then
        return 200
    end

    return nil
end

local function findBestPowerup()
    local folder = getPowerupFolder()
    local rootPart = getRootPart()

    if not folder or not rootPart then
        return nil
    end

    local healthPercentage = getHealthPercentage()
    local bestPart = nil
    local bestScore = -math.huge

    for _, child in ipairs(folder:GetChildren()) do
        local targetPart = findFirstBasePart(child)
        local score = scorePowerup(child, healthPercentage)
        local isValidTarget = targetPart and validateTravelTarget(targetPart, rootPart)

        if isValidTarget and score then
            local distance = (rootPart.Position - targetPart.Position).Magnitude
            local finalScore = score - (distance * 0.01)

            if finalScore > bestScore then
                bestScore = finalScore
                bestPart = targetPart
            end
        end
    end

    return bestPart
end

local function getEnemyFolder()
    local entities = workspace:FindFirstChild("Entities")
    return entities and entities:FindFirstChild("PirateDynasty")
end

local function getEnemyProfile(enemy)
    local enemyType = string.lower(tostring(enemy:GetAttribute("EnemyType") or ""))
    local enemyKind = string.lower(tostring(enemy:GetAttribute("PirateDynastyKind") or ""))

    if enemyType == "boss" or enemyKind == "boss" then
        return "boss"
    end

    if enemyKind == "ranged" then
        return "ranged"
    end

    return "melee"
end

local function getPositiveConfigNumber(name, fallback, minimum)
    local value = tonumber(_G.PirateDynastyConfigV14[name])

    if not value or value < minimum then
        return fallback
    end

    return value
end

local function beginBossHoldIfNeeded(enemy)
    if getEnemyProfile(enemy) ~= "boss" or heldBosses[enemy] then
        return
    end

    heldBosses[enemy] = true

    -- Skip spawn hold if the boss is already within attack range.
    local rootPart = getRootPart()
    local anchorPart = getBossAnchorPart(enemy)
    local maxBoss = getPositiveConfigNumber("MaxBossTravelDistance", DEFAULT_MAX_BOSS_TRAVEL_DISTANCE, 1)
    local skipThreshold = maxBoss / 4

    if rootPart and anchorPart then
        local dist = (anchorPart.Position - rootPart.Position).Magnitude
        if dist <= skipThreshold then
            bossHoldUntil = 0
            debugLog("boss within attack range (" .. string.format("%.1f", dist) .. " studs); skipping spawn hold")
            return
        end
    end

    bossHoldUntil = os.clock() + getPositiveConfigNumber("BossSpawnHoldSeconds", 3, 0)
    debugLog("new boss targeted; holding position before approach")
end

hasUnheldBossSpawned = function()
    local folder = getEnemyFolder()

    if not folder then
        return false
    end

    for _, enemy in ipairs(folder:GetChildren()) do
        local enemyRoot = enemy:IsA("Model") and enemy:FindFirstChild("HumanoidRootPart")
        local health = tonumber(enemy:GetAttribute("Health"))

        if enemy:IsA("Model")
            and enemy.Parent
            and not heldBosses[enemy]
            and getEnemyProfile(enemy) == "boss"
            and enemyRoot
            and health
            and health > 0
            and isPositionWithinPlayableY(enemyRoot.Position)
        then
            return true
        end
    end

    return false
end

local function getHoverOffset(enemy)
    local profile = getEnemyProfile(enemy)
    local config = _G.PirateDynastyConfigV14

    if profile == "boss" then
        return Vector3.new(0, tonumber(config.BossHoverHeight) or 24, 0)
    end

    if profile == "ranged" then
        return Vector3.new(0, tonumber(config.RangedHoverHeight) or 24, 0)
    end

    return Vector3.new(0, tonumber(config.MeleeHoverHeight) or 18, 0)
end

local function isValidEnemy(enemy)
    if not enemy or not enemy:IsA("Model") or not enemy.Parent then
        return false
    end

    local health = tonumber(enemy:GetAttribute("Health"))

    if not health or health <= 0 then
        return false
    end

    local rootPart = getRootPart()
    local profile = getEnemyProfile(enemy)

    if profile == "boss" then
        -- For bosses: only require alive + HP > 0 + within distance.
        -- Skip Y-gap and playable-Y checks; bosses teleport above the map during
        -- phase transitions and should never be dropped just because they are high up.
        local anchorPart = getBossAnchorPart(enemy)

        if not anchorPart then
            return false
        end

        if not isInstanceAlive(anchorPart) then
            return false
        end

        local maxBossTravelDistance = getPositiveConfigNumber(
            "MaxBossTravelDistance",
            DEFAULT_MAX_BOSS_TRAVEL_DISTANCE,
            1
        )
        local distance = rootPart and (anchorPart.Position - rootPart.Position).Magnitude

        if distance and distance <= maxBossTravelDistance then
            bossOutOfRangeUntil = 0
            return true
        end

        if bossOutOfRangeUntil == 0 then
            local graceSecs = getPositiveConfigNumber(
                "BossOutOfRangeGraceSeconds",
                DEFAULT_BOSS_OUT_OF_RANGE_GRACE_SECONDS,
                0
            )
            bossOutOfRangeUntil = os.clock() + graceSecs
        end

        return os.clock() < bossOutOfRangeUntil
    end

    local enemyRoot = enemy:FindFirstChild("HumanoidRootPart")

    if not enemyRoot then
        return false
    end

    if not validateTravelTarget(enemyRoot, rootPart) then
        return false
    end

    local maxEnemyTravelDistance = getPositiveConfigNumber(
        "MaxEnemyTravelDistance",
        DEFAULT_MAX_ENEMY_TRAVEL_DISTANCE,
        1
    )
    local distance = rootPart and (enemyRoot.Position - rootPart.Position).Magnitude

    return distance ~= nil and distance <= maxEnemyTravelDistance
end

local function scoreEnemy(enemy, distance)
    local profile = getEnemyProfile(enemy)

    if profile == "boss" then
        return 1000000 - distance
    end

    if profile == "ranged" then
        return 100000 - distance
    end

    return -distance
end

local function findBestEnemy()
    local folder = getEnemyFolder()
    local rootPart = getRootPart()

    if not folder or not rootPart then
        return nil
    end

    local bestEnemy = nil
    local bestScore = -math.huge

    for _, enemy in ipairs(folder:GetChildren()) do
        if isValidEnemy(enemy) then
            local isBossEnemy = getEnemyProfile(enemy) == "boss"
            local anchorPart = isBossEnemy
                and getBossAnchorPart(enemy)
                or enemy:FindFirstChild("HumanoidRootPart")

            if not anchorPart then
                continue
            end

            local distance = (rootPart.Position - anchorPart.Position).Magnitude
            local score = scoreEnemy(enemy, distance)

            if score > bestScore then
                bestScore = score
                bestEnemy = enemy
            end
        end
    end

    return bestEnemy
end

local function attackEnemy(enemy)
    local rootPart = getRootPart()

    if not rootPart or not isValidEnemy(enemy) then
        attackDumpStats.invalidEnemy += 1
        return false
    end

    local profile = getEnemyProfile(enemy)
    local enemyRoot = profile == "boss"
        and getBossAnchorPart(enemy)
        or (enemy and enemy:FindFirstChild("HumanoidRootPart"))

    if not enemyRoot then
        attackDumpStats.invalidEnemy += 1
        return false
    end

    local now = os.clock()

    local cooldown = profile == "boss"
        and getPositiveConfigNumber("BossAttackCooldown", 0.04, 0.01)
        or getPositiveConfigNumber("NormalAttackCooldown", 0.055, 0.01)

    if now - lastAttackAt < cooldown then
        attackDumpStats.cooldownBlocked += 1
        return false
    end

    local delta = enemyRoot.Position - rootPart.Position
    local direction = delta.Magnitude > 0 and delta.Unit or rootPart.CFrame.LookVector
    local attackData = {
        Action = "Basic",
        Direction = direction,
    }

    local success, errorMessage = pcall(function()
        interfaceEvent:FireServer("PirateDynastyAction", attackData)
    end)

    if success then
        lastAttackAt = now
        attackDumpStats.remoteSent += 1
        return true
    end

    attackDumpStats.remoteFailed += 1
    warn("[" .. VERSION .. "] attack failed: " .. tostring(errorMessage))
    return false
end

local function isAtCombatPosition(enemy)
    local rootPart = getRootPart()

    if not rootPart or not isValidEnemy(enemy) then
        return false
    end

    local isBoss = getEnemyProfile(enemy) == "boss"
    local enemyRoot = isBoss
        and getBossAnchorPart(enemy)
        or (enemy and enemy:FindFirstChild("HumanoidRootPart"))

    if not enemyRoot then
        return false
    end

    local destination = isBoss
        and getSafeBossDestination(enemyRoot, getHoverOffset(enemy), rootPart)
        or getSafeDestination(enemyRoot, getHoverOffset(enemy), rootPart)

    if not destination then
        return false
    end

    local profile = getEnemyProfile(enemy)
    local tolerance = getPositiveConfigNumber("CombatAttackTolerance", 10, 1)

    if profile == "boss" then
        tolerance = getPositiveConfigNumber("BossAttackTolerance", 40, 1)
    elseif profile == "ranged" then
        tolerance = getPositiveConfigNumber("RangedAttackTolerance", 30, 1)
    end

    return (rootPart.Position - destination.Position).Magnitude <= tolerance
end

local function runPowerupState()
    if not isInstanceAlive(cachedPotionTarget) then
        return false
    end

    if cachedEnemyTarget and getEnemyProfile(cachedEnemyTarget) == "boss" then
        local powerupName = string.lower(tostring(cachedPotionTarget.Name or ""))
        local isHealthPotion = string.find(powerupName, "health", 1, true)

        if not isHealthPotion then
            cachedPotionTarget = nil
            return false
        end

        local threshold = tonumber(_G.PirateDynastyConfigV14.HealthPickupThreshold) or 70
        if getHealthPercentage() >= threshold then
            cachedPotionTarget = nil
            return false
        end
    end

    clearActiveCombatTarget("collecting-powerup", cachedEnemyTarget)
    setState("COLLECT_POWERUP")
    moveTo(cachedPotionTarget, Vector3.new(0, 3, 0))
    cachedPotionTarget = nil
    return true
end

local function runEnemyState()
    if not isValidEnemy(cachedEnemyTarget) then
        clearActiveCombatTarget("enemy-invalid-before-run", cachedEnemyTarget)
        cachedEnemyTarget = nil
        return false
    end

    local rootPart = getRootPart()
    local isBoss = getEnemyProfile(cachedEnemyTarget) == "boss"
    local enemyRoot = isBoss
        and getBossAnchorPart(cachedEnemyTarget)
        or cachedEnemyTarget:FindFirstChild("HumanoidRootPart")

    if not rootPart or not enemyRoot then
        return false
    end

    beginBossHoldIfNeeded(cachedEnemyTarget)

    if getEnemyProfile(cachedEnemyTarget) == "boss" and os.clock() < bossHoldUntil then
        clearActiveCombatTarget("boss-spawn-hold", cachedEnemyTarget)
        setState("WAIT_BOSS_SPAWN")
        return true
    end

    local hoverOffset = getHoverOffset(cachedEnemyTarget)
    local destination, validationReason = isBoss
        and getSafeBossDestination(enemyRoot, hoverOffset, rootPart)
        or getSafeDestination(enemyRoot, hoverOffset, rootPart)

    -- Set activeCombatTarget early so the attack worker fires even if
    -- destination is temporarily invalid during a boss phase transition.
    activeCombatTarget = cachedEnemyTarget

    if not destination then
        if isBoss then
            local rootPart2 = getRootPart()
            if rootPart2 and enemyRoot then
                rootPart2.CFrame = CFrame.new(
                    rootPart2.Position,
                    Vector3.new(enemyRoot.Position.X, rootPart2.Position.Y, enemyRoot.Position.Z)
                )
            end
            setState("ATTACK_ENEMY")
            return true
        end
        clearActiveCombatTarget("enemy-destination-" .. tostring(validationReason), cachedEnemyTarget)
        cachedEnemyTarget = nil
        return true
    end

    local positionError = (rootPart.Position - destination.Position).Magnitude
    local shortSnapDistance = getPositiveConfigNumber("ShortSnapDistance", 14, 1)

    if positionError > shortSnapDistance then
        setState("CHASE_ENEMY")
        moveTo(enemyRoot, hoverOffset, isBoss)
    elseif positionError > REPOSITION_DISTANCE then
        setState("TRACK_ENEMY")
        rootPart.CFrame = destination
    end

    if hasUnheldBossSpawned() then
        clearActiveCombatTarget("unheld-boss-spawned", cachedEnemyTarget)
        return true
    end

    rootPart = getRootPart()
    enemyRoot = isBoss
        and getBossAnchorPart(cachedEnemyTarget)
        or (cachedEnemyTarget and cachedEnemyTarget:FindFirstChild("HumanoidRootPart"))

    if not rootPart or not enemyRoot or not isValidEnemy(cachedEnemyTarget) then
        clearActiveCombatTarget("enemy-invalid-after-move", cachedEnemyTarget)
        cachedEnemyTarget = nil
        return true
    end

    hoverOffset = getHoverOffset(cachedEnemyTarget)
    destination, validationReason = isBoss
        and getSafeBossDestination(enemyRoot, hoverOffset, rootPart)
        or getSafeDestination(enemyRoot, hoverOffset, rootPart)

    if not destination then
        if isBoss then
            setState("ATTACK_ENEMY")
            return true
        end
        debugLog("skip combat position: " .. tostring(validationReason))
        clearActiveCombatTarget("combat-position-" .. tostring(validationReason), cachedEnemyTarget)
        cachedEnemyTarget = nil
        return true
    end

    positionError = (rootPart.Position - destination.Position).Magnitude

    if positionError <= shortSnapDistance then
        rootPart.CFrame = destination
    end

    if isAtCombatPosition(cachedEnemyTarget) then
        setState("ATTACK_ENEMY")
    else
        setState("TRACK_ENEMY")
    end

    return true
end

local function runCaptureState()
    local captureCircle = workspace:FindFirstChild("PirateDynastyCaptureCircle")
    local rootPart = getRootPart()

    if not captureCircle or not captureCircle:IsA("BasePart") or not rootPart then
        return false
    end

    local isValidTarget = validateTravelTarget(captureCircle, rootPart)

    if not isValidTarget then
        return false
    end

    clearActiveCombatTarget("moving-to-checkpoint", cachedEnemyTarget)
    setState("CAPTURE_POINT")
    moveTo(captureCircle, Vector3.new(0, 5, 0))
    return true
end

local function resetAttackDumpStats(now)
    for key in pairs(attackDumpStats) do
        attackDumpStats[key] = 0
    end

    attackDumpStats.windowStartedAt = now
end

local function printAttackDumpIfDue()
    if not _G.PirateDynastyAttackDumpV14 then
        return
    end

    local now = os.clock()
    local interval = getPositiveConfigNumber("AttackDumpIntervalSeconds", 1, 0.5)

    if now - attackDumpStats.windowStartedAt < interval then
        return
    end

    local target = activeCombatTarget
    local profile = target and getEnemyProfile(target) or "none"
    local rootPart = getRootPart()
    local enemyRoot = target and target:FindFirstChild("HumanoidRootPart")
    local distance = rootPart and enemyRoot
        and string.format("%.1f", (rootPart.Position - enemyRoot.Position).Magnitude)
        or "n/a"

    local message = string.format(
        "[%s][ATTACK-DUMP] profile=%s distance=%s ticks=%d noTarget=%d bossHold=%d unheldBoss=%d outsideTolerance=%d ready=%d invalidEnemy=%d cooldownBlocked=%d remoteSent=%d remoteFailed=%d",
        VERSION,
        profile,
        distance,
        attackDumpStats.ticks,
        attackDumpStats.noTarget,
        attackDumpStats.bossHold,
        attackDumpStats.unheldBoss,
        attackDumpStats.outsideTolerance,
        attackDumpStats.ready,
        attackDumpStats.invalidEnemy,
        attackDumpStats.cooldownBlocked,
        attackDumpStats.remoteSent,
        attackDumpStats.remoteFailed
    )

    print(message)
    addRuntimeLog("ATTACK-DUMP", message)

    resetAttackDumpStats(now)
end

print("[" .. VERSION .. "] loaded")
print("[" .. VERSION .. "] use _G.PirateDynastyAutoFarmV14 = false to stop")
print("[" .. VERSION .. "] runtime log file: " .. runtimeLogFilename)

addRuntimeLog("HEADER", "ANIME VANGUARDS MAIN SCRIPT RUNTIME LOG")
addRuntimeLog("HEADER", "SCRIPT TYPE: MAIN SCRIPT DIAGNOSTICS")
addRuntimeLog("HEADER", "VERSION: " .. VERSION)
addRuntimeLog("HEADER", "FILE: " .. runtimeLogFilename)

cleanupCosmeticEffects()

task.spawn(function()
    while task.wait(getPositiveConfigNumber("CleanupIntervalSeconds", 0.75, 0.25)) do
        if _G.PirateDynastyRunnerTokenV14 ~= runnerToken then
            return
        end

        if _G.PirateDynastyAutoFarmV14 then
            cleanupCosmeticEffects()
        end
    end
end)

task.spawn(function()
    while task.wait(getPositiveConfigNumber("AttackWorkerTickSeconds", 0.015, 0.01)) do
        if _G.PirateDynastyRunnerTokenV14 ~= runnerToken then
            return
        end

        attackDumpStats.ticks += 1

        if _G.PirateDynastyAutoFarmV14 then
            if not activeCombatTarget then
                attackDumpStats.noTarget += 1
            elseif os.clock() < bossHoldUntil then
                attackDumpStats.bossHold += 1
            elseif hasUnheldBossSpawned() then
                attackDumpStats.unheldBoss += 1
            elseif getEnemyProfile(activeCombatTarget) ~= "boss"
                and not isAtCombatPosition(activeCombatTarget)
            then
                -- Normal/ranged enemies: must be at position before attacking.
                attackDumpStats.outsideTolerance += 1
            else
                -- Boss: attack immediately regardless of position.
                -- Normal enemies that passed isAtCombatPosition also land here.
                attackDumpStats.ready += 1
                attackEnemy(activeCombatTarget)
            end
        end

        printAttackDumpIfDue()
    end
end)

task.spawn(function()
    while task.wait(getPositiveConfigNumber("MainTickSeconds", 0.045, 0.02)) do
        if _G.PirateDynastyRunnerTokenV14 ~= runnerToken then
            return
        end

        if not _G.PirateDynastyAutoFarmV14 then
            clearActiveCombatTarget("paused", cachedEnemyTarget)
            setState("PAUSED")
            continue
        end

        if not getRootPart() then
            clearActiveCombatTarget("character-missing-or-dead", cachedEnemyTarget)
            setState("WAIT_CHARACTER")
            continue
        end

        local now = os.clock()

        local needRescan = now - lastEnemyScanAt >= ENEMY_RESCAN_SECONDS
            or not isValidEnemy(cachedEnemyTarget)

        if needRescan then
            lastEnemyScanAt = now
            local prevTarget = cachedEnemyTarget
            cachedEnemyTarget = findBestEnemy()

            -- If we just lost a boss and still can't find one, start/extend the re-lock
            -- grace window so we keep trying instead of falling through to IDLE.
            if not cachedEnemyTarget
                and prevTarget
                and getEnemyProfile(prevTarget) == "boss"
            then
                if bossReLockUntil == 0 then
                    local graceSecs = getPositiveConfigNumber(
                        "BossReLockGraceSeconds",
                        DEFAULT_BOSS_RELOCK_GRACE_SECONDS,
                        0
                    )
                    bossReLockUntil = now + graceSecs
                end
            elseif cachedEnemyTarget then
                bossReLockUntil = 0
            end
        end

        -- Within the re-lock window: keep scanning until the boss reappears.
        if not cachedEnemyTarget and bossReLockUntil > 0 then
            if now < bossReLockUntil then
                setState("WAIT_BOSS_RELOCK")
                continue
            else
                bossReLockUntil = 0
            end
        end

        if cachedEnemyTarget and getEnemyProfile(cachedEnemyTarget) == "boss" then
            beginBossHoldIfNeeded(cachedEnemyTarget)

            if os.clock() < bossHoldUntil then
                clearActiveCombatTarget("boss-spawn-hold-main-loop", cachedEnemyTarget)
                setState("WAIT_BOSS_SPAWN")
                continue
            end
        end

        if now - lastPotionScanAt >= POTION_RESCAN_SECONDS then
            lastPotionScanAt = now
            cachedPotionTarget = findBestPowerup()
        end

        if runPowerupState() then
            continue
        end

        if runEnemyState() then
            continue
        end

        if runCaptureState() then
            continue
        end

        clearActiveCombatTarget("idle-no-valid-state", cachedEnemyTarget)
        setState("IDLE")
    end
end)
end

local function startCombat()
    if state.combatStarted then return true end
    stopCombatOnly()
    if config.QuietCombatDumps then
        _G.PirateDynastyAttackDumpV14 = false
        _G.PirateDynastyTargetLossDumpV14 = false
    end
    local ok, err = pcall(startCombatInternal)
    if not ok then
        state.reason = "combat error: " .. tostring(err)
        warnLog(state.reason)
        return false
    end
    state.combatStarted = true
    state.phase = "COMBAT"
    state.reason = "combat started"
    log("combat started")
    return true
end

local function runPreMatch(token)
    state.phase = "PRE_MATCH"
    state.reason = "selecting character"
    fireInterface({ StartMatch = false, Character = config.CharacterId })
    task.wait(config.RemoteDelaySeconds)

    state.phase = "RUNE_CHECK"
    local runes = waitUntil(token, readRunes, config.WaitForRunesSeconds, 0.25)
    state.runesReady = hasRequiredRunes(runes)
    if not state.runesReady then
        for _, runeId in ipairs(config.EquipRunes or {}) do
            fireInterface({ CharacterId = config.CharacterId, Action = "EquipRune", RuneId = runeId })
            task.wait(0.3)
        end
        runes = waitUntil(token, readRunes, config.WaitForRunesSeconds, 0.25)
        state.runesReady = hasRequiredRunes(runes)
    end

    local difficulty = state.runesReady and config.DifficultyWhenRunesReady or config.DifficultyWhenRunesMissing
    state.lastDifficulty = difficulty
    state.phase = "DIFFICULTY"
    fireInterface({ Difficulty = difficulty })
    log("difficulty=" .. tostring(difficulty) .. " | runesReady=" .. tostring(state.runesReady))
    task.wait(config.RemoteDelaySeconds)

    state.phase = "START_MATCH"
    fireInterface({ StartMatch = true, Character = config.CharacterId })
    log("start match sent")

    if not state.runesReady then
        state.reason = "runes missing; started easy only"
        if config.StartCombatAfterMatch then task.wait(2); startCombat() end
        return
    end

    state.phase = "MODIFIER"
    local targetModifier = config.TargetModifier
    local hasVote = waitUntil(token, function() return modifierVisible(targetModifier) end, config.WaitForVoteSeconds, 0.25)
    if hasVote then
        fireInterface({ Modifier = targetModifier })
        state.reason = "modifier selected"
        log("modifier selected=" .. tostring(targetModifier))
    else
        state.reason = "modifier not found; continuing"
        log(state.reason)
    end
    if config.StartCombatAfterMatch then task.wait(1); startCombat() end
end

local function start()
    if state.running then log("already running | phase=" .. tostring(state.phase)); return state end
    local token = HttpService:GenerateGUID(false)
    state.token = token
    state.running = true
    state.startedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
    state.stoppedAt = nil
    state.phase = "WAIT_RUNTIME"
    state.reason = "starting"

    task.spawn(function()
        local exists, source = waitUntil(token, detectPirateRuntime, config.WaitForRuntimeSeconds, 0.25)
        if not exists then
            state.phase = "STOPPED"
            state.reason = "pirate runtime not found"
            state.running = false
            warnLog(state.reason)
            return
        end
        state.runtimeSource = source
        state.reason = "runtime confirmed"
        log("runtime confirmed | source=" .. tostring(source))
        readDynastyLevel()
        log("dynastyLevel=" .. tostring(state.dynastyLevel or "<missing>") .. " | text=" .. tostring(state.dynastyLevelText))
        if isCombatRuntimeLoaded() then
            state.reason = "combat runtime exists"
            startCombat()
            return
        end
        runPreMatch(token)
    end)
    return state
end

local function stop()
    state.running = false
    state.token = nil
    state.phase = "STOPPED"
    state.reason = "manual stop"
    state.stoppedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
    stopCombatOnly()
    log("stopped")
end

local function snapshot()
    local exists, source = detectPirateRuntime()
    readDynastyLevel()
    return {
        version = VERSION,
        running = state.running,
        phase = state.phase,
        inPirateDynasty = exists,
        runtimeSource = exists and source or state.runtimeSource,
        dynastyLevel = state.dynastyLevel,
        dynastyLevelText = state.dynastyLevelText,
        character = config.CharacterId,
        difficulty = state.lastDifficulty,
        runesReady = state.runesReady,
        modifier = config.TargetModifier,
        combatStarted = state.combatStarted,
        reason = state.reason,
    }
end

local function status()
    local snap = snapshot()
    log("running=" .. tostring(snap.running) .. " | phase=" .. tostring(snap.phase) .. " | inPirate=" .. tostring(snap.inPirateDynasty) .. " | level=" .. tostring(snap.dynastyLevel or "<missing>") .. " | combat=" .. tostring(snap.combatStarted) .. " | reason=" .. tostring(snap.reason))
    return snap
end

_G.AVPirateDynastyStart = start
_G.AVPirateDynastyStop = stop
_G.AVPirateDynastyStatus = status
_G.AVPirateDynastySnapshot = snapshot
_G.AVStop = function()
    stop()
    if previousAVStop and previousAVStop ~= _G.AVStop then pcall(previousAVStop) end
end

log("loaded")
log("stop: _G.AVStop() | status: _G.AVPirateDynastyStatus()")
if config.Enabled ~= false and config.AutoStart ~= false then start() end