--[[
    AV GOAL COMPLETE CONTROLLER
    VERSION: V1.0

    Role:
    - Watch a lightweight goal-complete signal from Eyes/Controller/future logic.
    - Fire the central flow remote to return to Lobby after the target is complete.
    - Keep Brain read-only and keep Reader focused on Render/Upgrade only.

    Goal signals supported:
        _G.AVSetGoalComplete("reason")
        _G.AVGoalComplete = true
        _G.AVGoalComplete = function() return true, "reason" end
        _G.AVGoalState = { Complete = true, Reason = "reason" }

    Commands:
        _G.AVGoalControllerStart()
        _G.AVGoalControllerStop()
        _G.AVGoalControllerStatus()
        _G.AVSetGoalComplete(reason)
        _G.AVClearGoalComplete()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VERSION = "AV-GOAL-COMPLETE-CONTROLLER V1.0"

local DEFAULT_CONFIG = {
    Enabled = false,
    AutoStart = false,
    Action = "Lobby",
    RequireMatchEnd = false,
    DelayBeforeActionSeconds = 2.0,
    ActionCooldownSeconds = 10.0,
    PollSeconds = 1.0,
    Verbose = false,
}

local networking = ReplicatedStorage:WaitForChild("Networking")
local teleportEvent = networking:WaitForChild("TeleportEvent")

local state = {
    running = false,
    stopRequested = false,
    handledCount = 0,
    lastAction = "idle",
    lastReason = "idle",
    lastFireAt = 0,
    pending = false,
}

local previousAVStop = rawget(_G, "AVStop")

local function log(message)
    print("[Goal] " .. tostring(message))
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
    local root = rawget(_G, "AVControllerConfig")
    local source = type(root) == "table" and root.OnGoalComplete or nil
    local config = cloneMap(DEFAULT_CONFIG)

    if type(source) == "table" then
        for key, value in pairs(source) do
            config[key] = value
        end
    end

    config.DelayBeforeActionSeconds = tonumber(config.DelayBeforeActionSeconds) or DEFAULT_CONFIG.DelayBeforeActionSeconds
    config.ActionCooldownSeconds = tonumber(config.ActionCooldownSeconds) or DEFAULT_CONFIG.ActionCooldownSeconds
    config.PollSeconds = tonumber(config.PollSeconds) or DEFAULT_CONFIG.PollSeconds
    if config.Action ~= "Lobby" and config.Action ~= "Stop" then
        config.Action = "Lobby"
    end

    return config
end

local function readBrainSnapshot()
    if type(_G.AVBrainSnapshot) ~= "function" then
        return nil
    end

    local ok, snapshot = pcall(_G.AVBrainSnapshot)
    if ok and type(snapshot) == "table" then
        return snapshot
    end

    return nil
end

local function readGoalSignal()
    local marker = rawget(_G, "AVGoalComplete")

    if type(marker) == "function" then
        local ok, complete, reason = pcall(marker)
        if ok and complete == true then
            return true, reason or "AVGoalComplete function"
        end
    elseif marker == true then
        return true, rawget(_G, "AVGoalCompleteReason") or "AVGoalComplete flag"
    end

    local goalState = rawget(_G, "AVGoalState")
    if type(goalState) == "table" and goalState.Complete == true then
        return true, goalState.Reason or "AVGoalState"
    end

    return false, nil
end

local function clearGoalSignal()
    if type(rawget(_G, "AVGoalComplete")) ~= "function" then
        _G.AVGoalComplete = false
    end
    _G.AVGoalCompleteReason = nil

    local goalState = rawget(_G, "AVGoalState")
    if type(goalState) == "table" then
        goalState.Complete = false
        goalState.Reason = nil
    end
end

local function goalAllowedByBrain(config)
    if not config.RequireMatchEnd then
        return true, "match-end not required"
    end

    local snapshot = readBrainSnapshot()
    if not snapshot then
        return false, "Brain missing"
    end

    if snapshot.phase == "MATCH_END" and snapshot.endScreenVisible == true then
        return true, "match end confirmed"
    end

    return false, "waiting for MATCH_END"
end

local function fireAction(config, reason)
    if os.clock() - state.lastFireAt < config.ActionCooldownSeconds then
        state.lastReason = "cooldown"
        return false
    end

    state.pending = true
    state.lastReason = "scheduled: " .. tostring(reason)

    task.delay(config.DelayBeforeActionSeconds, function()
        if not state.running or state.stopRequested then
            state.pending = false
            return
        end

        local stillComplete, latestReason = readGoalSignal()
        if not stillComplete then
            state.pending = false
            state.lastReason = "goal signal cleared before action"
            return
        end

        local allowed, guardReason = goalAllowedByBrain(config)
        if not allowed then
            state.pending = false
            state.lastReason = guardReason
            return
        end

        if config.Action == "Stop" then
            state.lastAction = "Stop"
            state.handledCount += 1
            state.lastFireAt = os.clock()
            clearGoalSignal()
            state.stopRequested = true
            state.pending = false
            log("goal handled | action=Stop | reason=" .. tostring(latestReason or reason))
            return
        end

        teleportEvent:FireServer("Lobby")
        state.lastAction = "Lobby"
        state.handledCount += 1
        state.lastFireAt = os.clock()
        state.pending = false
        clearGoalSignal()
        log("remote fired | action=Lobby | reason=" .. tostring(latestReason or reason) .. " | count=" .. tostring(state.handledCount))
    end)

    return true
end

local function loop()
    while state.running and not state.stopRequested do
        local config = getConfig()

        if config.Enabled ~= true then
            state.lastReason = "disabled"
            task.wait(config.PollSeconds)
            continue
        end

        if not state.pending then
            local complete, reason = readGoalSignal()
            if complete then
                local allowed, guardReason = goalAllowedByBrain(config)
                if allowed then
                    fireAction(config, reason)
                else
                    state.lastReason = guardReason
                    if config.Verbose then
                        log("waiting | reason=" .. tostring(guardReason))
                    end
                end
            else
                state.lastReason = "waiting for goal"
            end
        end

        task.wait(config.PollSeconds)
    end

    state.running = false
    state.pending = false
    log("stopped | reason=" .. tostring(state.lastReason))
end

local function start()
    if state.running then
        log("already running")
        return false
    end

    local config = getConfig()
    if config.Enabled ~= true then
        state.lastReason = "disabled"
        log("not started | reason=disabled")
        return false
    end

    state.running = true
    state.stopRequested = false
    state.lastReason = "running"
    log("started")
    task.spawn(loop)
    return true
end

local function stop()
    state.stopRequested = true
    state.lastReason = "manual stop"
    log("stop requested")
end

local function status()
    local config = getConfig()
    log("running=" .. tostring(state.running)
        .. " | enabled=" .. tostring(config.Enabled)
        .. " | action=" .. tostring(config.Action)
        .. " | handled=" .. tostring(state.handledCount)
        .. " | pending=" .. tostring(state.pending)
        .. " | reason=" .. tostring(state.lastReason))
end

local function setGoalComplete(reason)
    _G.AVGoalComplete = true
    _G.AVGoalCompleteReason = reason or "manual"
    log("goal marked complete | reason=" .. tostring(_G.AVGoalCompleteReason))
end

_G.AVGoalControllerStart = start
_G.AVGoalControllerStop = stop
_G.AVGoalControllerStatus = status
_G.AVSetGoalComplete = setGoalComplete
_G.AVClearGoalComplete = clearGoalSignal

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
