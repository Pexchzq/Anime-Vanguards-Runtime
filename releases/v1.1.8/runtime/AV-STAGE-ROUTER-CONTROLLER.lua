--[[
    AV STAGE ROUTER CONTROLLER
    VERSION: V1.0

    Role:
    - Select a stage from _G.AVStageRouterConfig using account level.
    - Fire confirmed lobby start remotes:
        ReplicatedStorage.Networking.LobbyEvent:FireServer("AddMatch", MATCH_CONFIG)
        ReplicatedStorage.Networking.LobbyEvent:FireServer("StartMatch")
    - Controller-only remote owner. Brain/Eyes remain read-only.

    Commands:
        _G.AVStageRouterStart()
        _G.AVStageRouterStop()
        _G.AVStageRouterStatus()
        _G.AVStageRouterPrintDecision()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local VERSION = "AV-STAGE-ROUTER-CONTROLLER V1.0"

local DEFAULT_CONFIG = {
    Enabled = false,
    AutoStart = false,
    LobbyPlaceId = 16146832113,
    DelayBetweenRemotesSeconds = 3,
    VerifyTimeoutSeconds = 30,
    RetrySeconds = 5,
    Verbose = false,
    Rules = {},
}

local player = Players.LocalPlayer
while not player do
    Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
    player = Players.LocalPlayer
end

local state = {
    running = false,
    stopRequested = false,
    lastLevel = nil,
    lastRuleName = nil,
    lastMatch = nil,
    lastAction = "idle",
    reason = "idle",
}

local previousAVStop = rawget(_G, "AVStop")

local function log(message)
    print("[Stage] " .. tostring(message))
end

local function getLobbyEvent()
    local networking = ReplicatedStorage:FindFirstChild("Networking")
    return networking and networking:FindFirstChild("LobbyEvent")
end

local function getInterfaceEvent()
    local networking = ReplicatedStorage:FindFirstChild("Networking")
    return networking and networking:FindFirstChild("InterfaceEvent")
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

local function getConfig()
    local source = rawget(_G, "AVStageRouterConfig")
    local config = cloneMap(DEFAULT_CONFIG)
    config.Rules = cloneArray(DEFAULT_CONFIG.Rules)

    if type(source) == "table" then
        for key, value in pairs(source) do
            if key == "Rules" then
                config.Rules = cloneArray(value)
            else
                config[key] = value
            end
        end
    end

    return config
end

local function runtimeRootsExist()
    return Workspace:FindFirstChild("Map") ~= nil
        or Workspace:FindFirstChild("Entities") ~= nil
        or Workspace:FindFirstChild("Units") ~= nil
end

local function pirateDynastyRuntimeExists()
    local playerGui = player and player:FindFirstChild("PlayerGui")
    local hud = playerGui and playerGui:FindFirstChild("PirateDynastyHUD")
    if hud then
        return true, "PlayerGui.PirateDynastyHUD"
    end

    local entities = Workspace:FindFirstChild("Entities")
    if entities and entities:FindFirstChild("PirateDynasty") then
        return true, "Workspace.Entities.PirateDynasty"
    end

    return false, "<none>"
end

local function readLevel()
    local value = player:GetAttribute("Level")
    if typeof(value) == "number" then
        return value
    end
    return tonumber(value) or 0
end

local function matchWhen(when, level)
    local conditions = when or {}

    if conditions.MinLevel ~= nil and level < conditions.MinLevel then
        return false
    end

    if conditions.MaxLevel ~= nil and level >= conditions.MaxLevel then
        return false
    end

    return true
end

local function resolveRule(config)
    local level = readLevel()

    for _, rule in ipairs(config.Rules or {}) do
        if rule.Enabled ~= false and matchWhen(rule.When, level) then
            return rule, level
        end
    end

    return nil, level
end

local function serializeMatch(match)
    if type(match) ~= "table" then
        return "<none>"
    end

    return "Difficulty=" .. tostring(match.Difficulty)
        .. " | Act=" .. tostring(match.Act)
        .. " | StageType=" .. tostring(match.StageType)
        .. " | Stage=" .. tostring(match.Stage)
end

local function serializeRule(rule)
    if type(rule) ~= "table" then
        return "<none>"
    end

    if rule.Mode == "PirateDynasty" then
        local entry = type(rule.PirateDynastyEntry) == "table" and rule.PirateDynastyEntry or {}
        return "Mode=PirateDynasty | remoteConfigured=" .. tostring(entry.RemoteConfigured == true)
    end

    return serializeMatch(rule.Match)
end

local function printDecision()
    local config = getConfig()
    local rule, level = resolveRule(config)

    if not rule then
        log("decision | level=" .. tostring(level) .. " | rule=<none>")
        return
    end

    log("decision | level=" .. tostring(level) .. " | rule=" .. tostring(rule.Name) .. " | " .. serializeRule(rule))
end

local function waitForMatchRuntime(config)
    local deadline = os.clock() + config.VerifyTimeoutSeconds

    while state.running and not state.stopRequested and os.clock() < deadline do
        if runtimeRootsExist() then
            return true
        end
        task.wait(1)
    end

    return false
end

local function waitForPirateDynastyRuntime(config)
    local deadline = os.clock() + config.VerifyTimeoutSeconds

    while state.running and not state.stopRequested and os.clock() < deadline do
        local exists, source = pirateDynastyRuntimeExists()
        if exists then
            return true, source
        end
        task.wait(1)
    end

    return false, "pirate dynasty runtime not detected"
end

local function firePirateDynastyEntry(config, rule, level)
    local entry = type(rule.PirateDynastyEntry) == "table" and rule.PirateDynastyEntry or {}
    state.lastLevel = level
    state.lastRuleName = rule.Name
    state.lastMatch = nil
    state.lastAction = "PirateDynastyEntry"

    log("selected | level=" .. tostring(level) .. " | rule=" .. tostring(rule.Name) .. " | Mode=PirateDynasty")

    local exists, source = pirateDynastyRuntimeExists()
    if exists then
        log("pirate runtime detected | source=" .. tostring(source))
        if type(_G.AVPirateDynastyStart) == "function" then
            local ok, err = pcall(_G.AVPirateDynastyStart)
            if not ok then
                return false, "pirate controller start failed: " .. tostring(err)
            end
            return true, "pirate controller started"
        end
        return false, "PirateDynastyController missing"
    end

    if entry.RemoteConfigured ~= true then
        state.reason = "pirate dynasty entry remote not configured"
        log("waiting | reason=pirate dynasty entry remote not configured")
        return false, state.reason
    end

    if type(entry.Payload) ~= "table" then
        state.reason = "pirate dynasty entry payload missing"
        log("waiting | reason=pirate dynasty entry payload missing")
        return false, state.reason
    end

    local interfaceEvent = getInterfaceEvent()
    if not interfaceEvent then
        state.reason = "InterfaceEvent missing"
        log("waiting | reason=InterfaceEvent missing")
        return false, state.reason
    end

    local action = entry.RemoteAction or "PirateDynastySelect"
    log("fire PirateDynastyEntry | action=" .. tostring(action))
    interfaceEvent:FireServer(action, cloneMap(entry.Payload))

    local verified, verifySource = waitForPirateDynastyRuntime(config)
    if not verified then
        return false, verifySource
    end

    log("pirate runtime detected | source=" .. tostring(verifySource))
    if type(_G.AVPirateDynastyStart) ~= "function" then
        return false, "PirateDynastyController missing"
    end

    local ok, err = pcall(_G.AVPirateDynastyStart)
    if not ok then
        return false, "pirate controller start failed: " .. tostring(err)
    end

    return true, "pirate controller started"
end

local function fireSelectedMatch(config, rule, level)
    if rule.Mode == "PirateDynasty" then
        return firePirateDynastyEntry(config, rule, level)
    end

    local matchConfig = cloneMap(rule.Match)
    state.lastLevel = level
    state.lastRuleName = rule.Name
    state.lastMatch = matchConfig
    state.lastAction = "AddMatch"

    log("selected | level=" .. tostring(level) .. " | rule=" .. tostring(rule.Name) .. " | " .. serializeMatch(matchConfig))
    local lobbyEvent = getLobbyEvent()
    if not lobbyEvent then
        state.reason = "LobbyEvent missing"
        log("waiting | reason=LobbyEvent missing")
        return false
    end

    log("fire AddMatch")
    lobbyEvent:FireServer("AddMatch", matchConfig)

    task.wait(config.DelayBetweenRemotesSeconds)
    if state.stopRequested then
        return false, "manual stop"
    end

    if runtimeRootsExist() then
        return false, "runtime appeared before StartMatch"
    end

    state.lastAction = "StartMatch"
    local lobbyEvent = getLobbyEvent()
    if not lobbyEvent then
        state.reason = "LobbyEvent missing"
        log("waiting | reason=LobbyEvent missing")
        return false
    end

    log("fire StartMatch")
    lobbyEvent:FireServer("StartMatch")

    if waitForMatchRuntime(config) then
        log("match detected")
        return true, "match runtime detected"
    end

    return false, "match runtime not detected"
end

local function canRunInLobby(config)
    if game.PlaceId ~= config.LobbyPlaceId then
        return false, "not lobby placeId=" .. tostring(game.PlaceId)
    end

    if runtimeRootsExist() then
        return false, "match runtime already exists"
    end

    return true, "ok"
end

local function start()
    if state.running then
        log("already running")
        return false
    end

    local config = getConfig()
    if not config.Enabled then
        state.reason = "disabled"
        log("not started | reason=disabled")
        return false
    end

    state.running = true
    state.stopRequested = false
    state.reason = "running"

    task.spawn(function()
        while state.running and not state.stopRequested do
            local allowed, guardReason = canRunInLobby(config)
            if not allowed then
                state.reason = guardReason
                log("waiting | reason=" .. guardReason)
                task.wait(config.RetrySeconds)
                continue
            end

            local rule, level = resolveRule(config)
            if not rule then
                state.reason = "no matching stage rule"
                log("waiting | level=" .. tostring(level) .. " | reason=no matching stage rule")
                task.wait(config.RetrySeconds)
                continue
            end

            local ok, reason = fireSelectedMatch(config, rule, level)
            state.reason = reason
            if ok then
                state.running = false
                log("finished | reason=" .. reason)
                return
            end

            log("retry later | reason=" .. tostring(reason))
            task.wait(config.RetrySeconds)
        end

        state.running = false
        state.reason = state.stopRequested and "manual stop" or state.reason
        log("stopped | reason=" .. tostring(state.reason))
    end)

    return true
end

local function stop()
    state.stopRequested = true
    state.reason = "manual stop"
    log("stop requested")
end

local function status()
    local config = getConfig()
    log("running=" .. tostring(state.running)
        .. " | enabled=" .. tostring(config.Enabled)
        .. " | autoStart=" .. tostring(config.AutoStart)
        .. " | level=" .. tostring(readLevel())
        .. " | lastRule=" .. tostring(state.lastRuleName or "<none>")
        .. " | lastAction=" .. tostring(state.lastAction)
        .. " | reason=" .. tostring(state.reason))
end

_G.AVStageRouterStart = start
_G.AVStageRouterStop = stop
_G.AVStageRouterStatus = status
_G.AVStageRouterPrintDecision = printDecision

_G.AVStop = function()
    if type(previousAVStop) == "function" then
        pcall(previousAVStop)
    end
    stop()
end

log("loaded")

local initialConfig = getConfig()
if initialConfig.Enabled and initialConfig.AutoStart and not rawget(_G, "AVBootstrapManagedStartup") then
    start()
end
