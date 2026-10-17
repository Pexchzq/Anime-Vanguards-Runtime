--[[
    AV MACRO CONTROLLER
    VERSION: AV-MACRO-CONTROLLER V1.1 - STALE-GUARD

    Purpose:
    - Centralize match-flow remotes after EndScreen appears.
    - Brain reads state only.
    - Reader plays macro steps only.
    - Controller fires Retry / Next / Lobby only when Brain confirms MATCH_END.

    Public commands:
        _G.AVControllerStart()
        _G.AVControllerStop()
        _G.AVControllerStatus()
        _G.AVControllerFireRetry()
        _G.AVControllerFireNext()
        _G.AVControllerFireLobby()
        _G.AVStop()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VERSION = "AV-MACRO-CONTROLLER V1.1 - STALE-GUARD"
local MAX_BRAIN_SNAPSHOT_AGE = 3.5
local DEFAULT_CONFIG = {
    Version = 1,
    EndScreenPolicy = {
        DefaultAction = "Retry",
        RequireEndScreen = true,
        StableEndScreenSeconds = 1.5,
        DelayBeforeActionSeconds = 2.0,
        ActionCooldownSeconds = 4.0,
    },
    Rules = {
        {
            Name = "Defeat retry same map",
            Enabled = true,
            When = { OutcomeIn = { "DEFEAT", "FAILED" } },
            Action = "Retry",
        },
    },
}

local SCAN_INTERVAL = 0.5
local VALID_ACTIONS = {
    Retry = true,
    Next = true,
    Lobby = true,
    Stop = true,
}

local running = false
local stopRequested = false
local scanThread = nil
local lastStatusLine = nil
local stableEndScreenSince = nil
local lastHandledEndScreenKey = nil
local lastActionAt = 0
local actionCount = 0

local function log(message)
    print("[End] " .. tostring(message))
end

local function getNetworking()
    return ReplicatedStorage:FindFirstChild("Networking")
end

local function getEndScreenVoteEvent()
    local networking = getNetworking()
    local endScreen = networking and networking:FindFirstChild("EndScreen")
    return endScreen and endScreen:FindFirstChild("VoteEvent")
end

local function getTeleportEvent()
    local networking = getNetworking()
    return networking and networking:FindFirstChild("TeleportEvent")
end

local function trimUpper(text)
    text = tostring(text or "")
    text = string.gsub(text, "^%s*(.-)%s*$", "%1")
    return string.upper(text)
end

local function getConfig()
    if type(_G.AVControllerConfig) == "table" then
        return _G.AVControllerConfig
    end

    log("Controller config missing; using default Retry policy")
    return DEFAULT_CONFIG
end

local function getPolicy(config)
    config = config or getConfig()
    config.EndScreenPolicy = config.EndScreenPolicy or {}
    local policy = config.EndScreenPolicy
    policy.DefaultAction = policy.DefaultAction or "Retry"
    policy.StableEndScreenSeconds = tonumber(policy.StableEndScreenSeconds) or 1.5
    policy.DelayBeforeActionSeconds = tonumber(policy.DelayBeforeActionSeconds) or 2.0
    policy.ActionCooldownSeconds = tonumber(policy.ActionCooldownSeconds) or 4.0
    if policy.RequireEndScreen == nil then
        policy.RequireEndScreen = true
    end
    return policy
end

local function readBrainSnapshot()
    if type(_G.AVBrainSnapshot) ~= "function" then
        return nil, "Brain missing"
    end

    local ok, snapshot = pcall(_G.AVBrainSnapshot)
    if not ok or type(snapshot) ~= "table" then
        return nil, "Brain snapshot failed: " .. tostring(snapshot)
    end

    return snapshot, nil
end

local function listContains(list, value)
    value = trimUpper(value)
    if type(list) ~= "table" then
        return false
    end

    for _, item in ipairs(list) do
        if trimUpper(item) == value then
            return true
        end
    end

    return false
end

local function ruleMatches(rule, state)
    if type(rule) ~= "table" or rule.Enabled == false then
        return false
    end

    local when = rule.When or {}
    if when.OutcomeIn and not listContains(when.OutcomeIn, state.outcomeText) then
        return false
    end

    if when.MapName and tostring(when.MapName) ~= tostring(state.mapName) then
        return false
    end

    return true
end

local function chooseAction(config, state)
    for _, rule in ipairs(config.Rules or {}) do
        if ruleMatches(rule, state) then
            local action = tostring(rule.Action or "")
            if VALID_ACTIONS[action] then
                return action, rule.Name or "unnamed rule"
            end
            log("invalid rule action ignored | rule=" .. tostring(rule.Name) .. " | action=" .. tostring(rule.Action))
        end
    end

    local action = tostring(getPolicy(config).DefaultAction or "Retry")
    if not VALID_ACTIONS[action] then
        action = "Retry"
    end
    return action, "default policy"
end

local function endScreenKey(state)
    return table.concat({
        tostring(state.mapName or ""),
        tostring(state.outcomeText or ""),
        tostring(state.outcomePath or ""),
    }, "|")
end

local function fireAction(action)
    action = tostring(action or "")
    if action == "Retry" then
        local endScreenVoteEvent = getEndScreenVoteEvent()
        if not endScreenVoteEvent then
            return false, "EndScreen.VoteEvent missing"
        end
        endScreenVoteEvent:FireServer("Retry")
    elseif action == "Next" then
        local endScreenVoteEvent = getEndScreenVoteEvent()
        if not endScreenVoteEvent then
            return false, "EndScreen.VoteEvent missing"
        end
        endScreenVoteEvent:FireServer("Next")
    elseif action == "Lobby" then
        local teleportEvent = getTeleportEvent()
        if not teleportEvent then
            return false, "TeleportEvent missing"
        end
        teleportEvent:FireServer("Lobby")
    elseif action == "Stop" then
        log("policy action Stop; no remote fired")
        return true
    else
        return false, "unknown action " .. tostring(action)
    end

    actionCount += 1
    lastActionAt = os.clock()
    log("remote fired | action=" .. action .. " | count=" .. tostring(actionCount))
    return true, nil
end

local function isMatchEndStable(state, policy)
    if policy.RequireEndScreen and state.endScreenVisible ~= true then
        return false
    end

    if state.phase ~= "MATCH_END" then
        return false
    end

    if not stableEndScreenSince then
        stableEndScreenSince = os.clock()
        return false
    end

    return (os.clock() - stableEndScreenSince) >= policy.StableEndScreenSeconds
end

local function updateController()
    local state, err = readBrainSnapshot()
    if not state then
        if err ~= lastStatusLine then
            log(err)
            lastStatusLine = err
        end
        stableEndScreenSince = nil
        return
    end

    local config = getConfig()
    local policy = getPolicy(config)
    if state.snapshotStale == true or (tonumber(state.snapshotAgeSeconds) or 0) > MAX_BRAIN_SNAPSHOT_AGE then
        stableEndScreenSince = nil
        return
    end
    local statusLine = string.format(
        "phase=%s | map=%s | endScreen=%s | outcome=%s",
        tostring(state.phase),
        tostring(state.mapName),
        tostring(state.endScreenVisible),
        tostring(state.outcomeText or "<none>")
    )

    if statusLine ~= lastStatusLine then
        log(statusLine)
        lastStatusLine = statusLine
    end

    if state.endScreenVisible ~= true or state.phase ~= "MATCH_END" then
        stableEndScreenSince = nil
        lastHandledEndScreenKey = nil
        return
    end

    if not isMatchEndStable(state, policy) then
        return
    end

    if os.clock() - lastActionAt < policy.ActionCooldownSeconds then
        return
    end

    local key = endScreenKey(state)
    if key == lastHandledEndScreenKey then
        return
    end

    local action, reason = chooseAction(config, state)
    lastHandledEndScreenKey = key
    log("end screen policy matched | action=" .. tostring(action) .. " | reason=" .. tostring(reason))

    task.delay(policy.DelayBeforeActionSeconds, function()
        if not running or stopRequested then
            return
        end

        local latest = readBrainSnapshot()
        if type(latest) == "table" and latest.endScreenVisible == true and latest.phase == "MATCH_END" then
            local ok, fireErr = fireAction(action)
            if not ok then
                log("remote fire failed | " .. tostring(fireErr))
            end
        else
            log("remote skipped; EndScreen no longer stable")
        end
    end)
end

local function start()
    if running then
        log("already running")
        return
    end

    running = true
    stopRequested = false
    stableEndScreenSince = nil
    lastHandledEndScreenKey = nil
    lastStatusLine = nil
    log("controller started")

    scanThread = task.spawn(function()
        while running and not stopRequested do
            updateController()
            task.wait(SCAN_INTERVAL)
        end
        running = false
        log("controller stopped")
    end)
end

local function stop()
    if not running then
        log("already stopped")
        return
    end
    stopRequested = true
    running = false
end

local function status()
    local state = readBrainSnapshot()
    log(string.format(
        "running=%s | actions=%d | lastActionAt=%.2f | brainPhase=%s | endScreen=%s",
        tostring(running),
        actionCount,
        lastActionAt,
        type(state) == "table" and tostring(state.phase) or "<missing>",
        type(state) == "table" and tostring(state.endScreenVisible) or "<missing>"
    ))
end

local function fireRetry()
    return fireAction("Retry")
end

local function fireNext()
    return fireAction("Next")
end

local function fireLobby()
    return fireAction("Lobby")
end

_G.AVControllerStart = start
_G.AVControllerStop = stop
_G.AVControllerStatus = status
_G.AVControllerFireRetry = fireRetry
_G.AVControllerFireNext = fireNext
_G.AVControllerFireLobby = fireLobby

_G.AVStop = function()
    if type(_G.MacroReaderStop) == "function" then
        pcall(_G.MacroReaderStop)
    end
    stop()
    if type(_G.AVBrainStop) == "function" then
        pcall(_G.AVBrainStop)
    end
end
_G.AVMacroStop = _G.AVStop

log("loaded")

task.defer(start)
