--[[
    AV PIRATE DYNASTY CONTROLLER
    VERSION: V1.0

    Role:
    - Runs only after StageRouter confirms Pirate Dynasty runtime.
    - Uses InterfaceEvent remotes for Pirate Dynasty pre-match setup.
    - Does not enter Pirate Dynasty by itself.

    Commands:
        _G.AVPirateDynastyStart()
        _G.AVPirateDynastyStop()
        _G.AVPirateDynastyStatus()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local DEFAULT_CONFIG = {
    Enabled = true,
    AutoStart = false,
    CharacterId = "ElasticCaptainPirate",
    CharacterDisplayName = "Elastic Captain (Cog 4th)",
    RequiredRunes = {},
    EquipRunes = {},
    DifficultyWhenRunesReady = "Hard",
    DifficultyWhenRunesMissing = "Easy",
    TargetModifier = "Floodgates",
    WaitForRuntimeSeconds = 20,
    WaitForRunesSeconds = 6,
    WaitForVoteSeconds = 20,
    RemoteDelaySeconds = 0.5,
    StartCombatAfterMatch = false,
    RerollWhenModifierMissing = false,
    Verbose = false,
}

local player = Players.LocalPlayer
while not player do
    Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
    player = Players.LocalPlayer
end

local state = {
    running = false,
    stopRequested = false,
    runId = 0,
    phase = "idle",
    reason = "idle",
    lastDifficulty = nil,
    runeReady = false,
}

local previousAVStop = rawget(_G, "AVStop")

local function log(message)
    print("[Pirate] " .. tostring(message))
end

local function verboseLog(config, message)
    if config.Verbose then
        log(message)
    end
end

local function cloneArray(value)
    local copy = {}
    if type(value) == "table" then
        for index, item in ipairs(value) do
            copy[index] = item
        end
    end
    return copy
end

local function cloneMap(value)
    local copy = {}
    if type(value) == "table" then
        for key, item in pairs(value) do
            copy[key] = item
        end
    end
    return copy
end

local function mergeConfig(override)
    local source = type(_G.AVControllerConfig) == "table" and _G.AVControllerConfig.PirateDynasty or nil
    local config = cloneMap(DEFAULT_CONFIG)
    config.RequiredRunes = cloneArray(DEFAULT_CONFIG.RequiredRunes)
    config.EquipRunes = cloneArray(DEFAULT_CONFIG.EquipRunes)

    if type(source) == "table" then
        for key, value in pairs(source) do
            if key == "RequiredRunes" or key == "EquipRunes" then
                config[key] = cloneArray(value)
            else
                config[key] = value
            end
        end
    end

    if type(override) == "table" then
        for key, value in pairs(override) do
            if key == "RequiredRunes" or key == "EquipRunes" then
                config[key] = cloneArray(value)
            else
                config[key] = value
            end
        end
    end

    return config
end

local function getInterfaceEvent()
    local networking = ReplicatedStorage:FindFirstChild("Networking")
    return networking and networking:FindFirstChild("InterfaceEvent")
end

local function getPirateHud()
    local playerGui = player and player:FindFirstChild("PlayerGui")
    return playerGui and playerGui:FindFirstChild("PirateDynastyHUD")
end

local function pirateRuntimeExists()
    local hud = getPirateHud()
    if hud then
        return true, "PlayerGui.PirateDynastyHUD"
    end

    local entities = Workspace:FindFirstChild("Entities")
    if entities and entities:FindFirstChild("PirateDynasty") then
        return true, "Workspace.Entities.PirateDynasty"
    end

    return false, "<none>"
end

local function normalizeText(value)
    return string.upper(tostring(value or "")):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function fireSelect(payload)
    local interfaceEvent = getInterfaceEvent()
    if not interfaceEvent then
        return false, "InterfaceEvent missing"
    end

    interfaceEvent:FireServer("PirateDynastySelect", payload)
    return true, "sent"
end

local function waitForRuntime(config, runId)
    local deadline = os.clock() + config.WaitForRuntimeSeconds
    while state.running and not state.stopRequested and state.runId == runId and os.clock() < deadline do
        local exists, source = pirateRuntimeExists()
        if exists then
            return true, source
        end
        task.wait(0.5)
    end
    return false, "pirate runtime missing"
end

local function getRunesContainer()
    local hud = getPirateHud()
    local export = hud and hud:FindFirstChild("Export")
    local rightSide = export and export:FindFirstChild("RightSide")
    local container = rightSide and rightSide:FindFirstChild("Container")
    local frame = container and container:FindFirstChild("Frame")
    local runesContainer = frame and frame:FindFirstChild("RunesContainer")
    local panel = runesContainer and runesContainer:FindFirstChild("RunesPanel")
    return panel and panel:FindFirstChild("SlotsRow")
end

local function readRuneTexts()
    local results = {}
    local slotsRow = getRunesContainer()
    if not slotsRow then
        return results
    end

    for _, descendant in ipairs(slotsRow:GetDescendants()) do
        if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
            local text = descendant.Text
            if type(text) == "string" and text ~= "" then
                table.insert(results, text)
            end
        end
    end

    return results
end

local function hasRequiredRunes(config)
    if #config.RequiredRunes == 0 then
        return true
    end

    local joined = normalizeText(table.concat(readRuneTexts(), " | "))
    if joined == "" then
        return false
    end

    for _, required in ipairs(config.RequiredRunes) do
        if not string.find(joined, normalizeText(required), 1, true) then
            return false
        end
    end

    return true
end

local function waitForRunes(config, runId)
    local deadline = os.clock() + config.WaitForRunesSeconds
    while state.running and not state.stopRequested and state.runId == runId and os.clock() < deadline do
        if hasRequiredRunes(config) then
            return true
        end
        task.wait(0.5)
    end
    return hasRequiredRunes(config)
end

local function equipConfiguredRunes(config, runId)
    if #config.EquipRunes == 0 then
        return
    end

    for _, runeId in ipairs(config.EquipRunes) do
        if not state.running or state.stopRequested or state.runId ~= runId then
            return
        end

        local ok, reason = fireSelect({
            CharacterId = config.CharacterId,
            Action = "EquipRune",
            RuneId = runeId,
        })

        if ok then
            verboseLog(config, "fire EquipRune | rune=" .. tostring(runeId))
        else
            log("waiting | reason=" .. tostring(reason))
            return
        end

        task.wait(config.RemoteDelaySeconds)
    end
end

local function findModifierTitle(config)
    local hud = getPirateHud()
    local vote = hud and hud:FindFirstChild("SeaConditionsVote")
    local row = vote and vote:FindFirstChild("OptionsRow")
    if not row then
        return false
    end

    local target = normalizeText(config.TargetModifier)
    for _, descendant in ipairs(row:GetDescendants()) do
        if (descendant:IsA("TextLabel") or descendant:IsA("TextButton")) and descendant.Name == "Title" then
            if descendant.Visible and string.find(normalizeText(descendant.Text), target, 1, true) then
                return true
            end
        end
    end

    return false
end

local function waitAndSelectModifier(config, runId)
    if not config.TargetModifier or config.TargetModifier == "" then
        return true, "no modifier target"
    end

    local deadline = os.clock() + config.WaitForVoteSeconds
    while state.running and not state.stopRequested and state.runId == runId and os.clock() < deadline do
        if findModifierTitle(config) then
            local ok, reason = fireSelect({ Modifier = config.TargetModifier })
            if ok then
                log("modifier selected | " .. tostring(config.TargetModifier))
                return true, "modifier selected"
            end
            return false, reason
        end
        task.wait(0.5)
    end

    log("modifier not found | target=" .. tostring(config.TargetModifier))
    return false, "modifier not found"
end

local function start(overrideConfig)
    if state.running then
        log("already running")
        return false
    end

    local config = mergeConfig(overrideConfig)
    if not config.Enabled then
        state.reason = "disabled"
        log("not started | reason=disabled")
        return false
    end

    state.running = true
    state.stopRequested = false
    state.runId += 1
    local runId = state.runId

    task.spawn(function()
        state.phase = "wait-runtime"
        local runtimeOk, runtimeSource = waitForRuntime(config, runId)
        if not runtimeOk then
            state.reason = runtimeSource
            log("stopped | reason=" .. tostring(runtimeSource))
            state.running = false
            return
        end

        log("runtime confirmed | source=" .. tostring(runtimeSource))

        state.phase = "select-character"
        fireSelect({
            StartMatch = false,
            Character = config.CharacterId,
        })
        task.wait(config.RemoteDelaySeconds)

        state.phase = "rune-check"
        local runeReady = waitForRunes(config, runId)
        if not runeReady then
            equipConfiguredRunes(config, runId)
            runeReady = waitForRunes(config, runId)
        end
        state.runeReady = runeReady

        state.phase = "difficulty"
        local difficulty = runeReady and config.DifficultyWhenRunesReady or config.DifficultyWhenRunesMissing
        state.lastDifficulty = difficulty
        fireSelect({ Difficulty = difficulty })
        log("difficulty selected | " .. tostring(difficulty) .. " | runesReady=" .. tostring(runeReady))
        task.wait(config.RemoteDelaySeconds)

        state.phase = "start-match"
        fireSelect({
            StartMatch = true,
            Character = config.CharacterId,
        })
        log("start match sent | character=" .. tostring(config.CharacterId))

        if difficulty == config.DifficultyWhenRunesReady then
            state.phase = "modifier"
            waitAndSelectModifier(config, runId)
        end

        state.phase = "combat"
        if config.StartCombatAfterMatch and type(_G.AVPirateDynastyCombatStart) == "function" then
            local ok, err = pcall(_G.AVPirateDynastyCombatStart)
            if not ok then
                log("combat start failed | " .. tostring(err))
            end
        else
            verboseLog(config, "combat start skipped")
        end

        state.reason = "pre-match flow complete"
        state.running = false
        log("finished | reason=" .. tostring(state.reason))
    end)

    return true
end

local function stop()
    state.stopRequested = true
    state.runId += 1
    state.reason = "manual stop"
    log("stop requested")
end

local function status()
    local config = mergeConfig()
    log("running=" .. tostring(state.running)
        .. " | enabled=" .. tostring(config.Enabled)
        .. " | phase=" .. tostring(state.phase)
        .. " | difficulty=" .. tostring(state.lastDifficulty or "<none>")
        .. " | runesReady=" .. tostring(state.runeReady)
        .. " | reason=" .. tostring(state.reason))
end

_G.AVPirateDynastyStart = start
_G.AVPirateDynastyStop = stop
_G.AVPirateDynastyStatus = status

_G.AVStop = function()
    if type(previousAVStop) == "function" then
        pcall(previousAVStop)
    end
    stop()
end

log("loaded")

local initialConfig = mergeConfig()
if initialConfig.Enabled and initialConfig.AutoStart and not rawget(_G, "AVBootstrapManagedStartup") then
    start()
end
