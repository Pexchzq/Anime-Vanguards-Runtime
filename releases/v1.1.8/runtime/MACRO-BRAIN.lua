--[[
    ANIME VANGUARDS MACRO BRAIN STATE
    SCRIPT TYPE: MAIN / SHARED STATE READER
    VERSION: MAIN-SCRIPT V1.7 - CACHED

    Purpose:
    - Central "brain" for macro recorder/reader scripts.
    - Read the current runtime state once in a consistent format.
    - Keep map/end-screen logic out of recorder/reader files so they do not duplicate paths.
    - This file is read-only. It does not fire remotes and does not click UI.

    Why this exists:
    - Workspace.Map can disappear during transitions, so it must not be used alone as "match ended".
    - Runtime GUIDs change every match, so macro identity must not be based on fixed GUIDs.
    - EndScreen / MatchSummary is the confirmed signal that the match is finished.

    Confirmed paths used:
    - Current map name:
        workspace.Map:GetAttribute("MapName")
    - Pirate Dynasty match outcome:
        Players.LocalPlayer.PlayerGui.PirateDynastyHUD.MatchSummaryBackdrop.Card.TitleStrip.Outcome.Text
    - Active enemies/entities after the stage starts:
        workspace.Entities
    - Placed units:
        workspace.Units.<GUID>

    Public commands:
        _G.AVBrainStart()
        _G.AVBrainStop()
        _G.AVBrainStatus()
        _G.AVBrainSnapshot()
        _G.AVBrainCanStartMacro(expectedMapName)
        _G.AVBrainPrintSnapshot()

    Suggested usage by Macro Reader:
        local state = _G.AVBrainSnapshot()
        if state.endScreenVisible then
            -- match is finished; stop macro loop and wait for replay/new start
        end
        if state.mapName == expectedMapName and state.placedUnits == 0 and not state.endScreenVisible then
            -- safe candidate for starting from step 1
        end

    Important:
    - This brain detects "current state"; it does not decide policy by itself.
    - Reader should decide whether to start, stop, retry, or wait based on this snapshot.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local VERSION = "AV-MACRO-BRAIN MAIN-SCRIPT V1.7 - CACHED"
local DEFAULT_MAP_NAME = "UNKNOWN_MAP"
local SCAN_INTERVAL = 1.0
local STALE_AFTER_SECONDS = 3.0

local player = Players.LocalPlayer
local running = false
local scanThread = nil
local scanCount = 0
local lastSnapshot = nil
local lastSignature = nil
local lastScanClock = nil

local function log(message)
    print("[Brain] " .. tostring(message))
end

local function isGuidLike(text)
    return string.match(
        string.lower(tostring(text or "")),
        "^[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+$"
    ) ~= nil
end

local function trim(text)
    return string.gsub(tostring(text or ""), "^%s*(.-)%s*$", "%1")
end

local function readMapState()
    local map = Workspace:FindFirstChild("Map")
    if not map then
        return {
            mapExists = false,
            mapName = DEFAULT_MAP_NAME,
            mapNameReason = "Workspace.Map missing",
            mapPath = "Workspace.Map",
            mapNamePath = "Workspace.Map:GetAttribute(\"MapName\")",
        }
    end

    local value = map:GetAttribute("MapName")
    if value == nil or trim(value) == "" then
        return {
            mapExists = true,
            mapName = DEFAULT_MAP_NAME,
            mapNameReason = "MapName attribute missing/empty",
            mapPath = map:GetFullName(),
            mapNamePath = "Workspace.Map:GetAttribute(\"MapName\")",
        }
    end

    return {
        mapExists = true,
        mapName = tostring(value),
        mapNameReason = nil,
        mapPath = map:GetFullName(),
        mapNamePath = "Workspace.Map:GetAttribute(\"MapName\")",
    }
end

local function readOutcomeState()
    local gui = player:FindFirstChild("PlayerGui")
    local hud = gui and gui:FindFirstChild("PirateDynastyHUD")
    local backdrop = hud and hud:FindFirstChild("MatchSummaryBackdrop")
    local card = backdrop and backdrop:FindFirstChild("Card")
    local titleStrip = card and card:FindFirstChild("TitleStrip")
    local outcome = titleStrip and titleStrip:FindFirstChild("Outcome")

    if not outcome or not outcome:IsA("TextLabel") then
        return nil, "confirmed outcome label missing"
    end

    local text = trim(outcome.Text)
    local visible = outcome.Visible and text ~= ""

    if not visible then
        return nil, "confirmed outcome hidden/empty"
    end

    return {
        endScreenVisible = visible,
        outcomeText = text,
        outcomePath = outcome:GetFullName(),
        outcomeReason = nil,
        endScreenSource = "confirmed-outcome-path",
    }, nil
end

local function readFallbackEndScreenState()
    local gui = player:FindFirstChild("PlayerGui")
    if not gui then
        return {
            endScreenVisible = false,
            outcomeText = nil,
            outcomePath = "PlayerGui",
            outcomeReason = "PlayerGui missing",
            endScreenSource = "fallback-text-scan",
        }
    end

    local foundOutcome = nil
    local foundOutcomePath = nil
    local foundRetry = false
    local foundLobby = false
    local foundRewards = false
    local foundStages = false

    for _, item in ipairs(gui:GetDescendants()) do
        if item:IsA("TextLabel") or item:IsA("TextButton") then
            local text = trim(item.Text)
            if item.Visible and text ~= "" then
                local lower = string.lower(text)
                if lower == "failed" or lower == "defeat" or lower == "victory" or lower == "complete" or lower == "cleared" then
                    foundOutcome = text
                    foundOutcomePath = item:GetFullName()
                elseif string.find(lower, "retry", 1, true) then
                    foundRetry = true
                elseif string.find(lower, "return to lobby", 1, true) then
                    foundLobby = true
                elseif string.find(lower, "rewards", 1, true) then
                    foundRewards = true
                elseif string.find(lower, "stages/bounties", 1, true) then
                    foundStages = true
                end
            end
        end
    end

    local looksLikeEndScreen = foundOutcome ~= nil and (foundRetry or foundLobby or foundRewards or foundStages)
    return {
        endScreenVisible = looksLikeEndScreen,
        outcomeText = looksLikeEndScreen and foundOutcome or nil,
        outcomePath = foundOutcomePath or "PlayerGui text fallback scan",
        outcomeReason = looksLikeEndScreen and nil or "no end-screen text pattern found",
        endScreenSource = "fallback-text-scan",
    }
end

local function readEndScreenState()
    local confirmed, confirmedReason = readOutcomeState()
    if confirmed then
        return confirmed
    end

    local fallback = readFallbackEndScreenState()
    if fallback.endScreenVisible then
        fallback.confirmedPathReason = confirmedReason
    end
    return fallback
end

local function countPlacedUnits()
    local units = Workspace:FindFirstChild("Units")
    if not units then
        return 0, "Workspace.Units missing"
    end

    local count = 0
    for _, child in ipairs(units:GetChildren()) do
        if child:IsA("Model") and isGuidLike(child.Name) then
            count += 1
        end
    end

    return count, nil
end

local function countActiveEntities()
    local entities = Workspace:FindFirstChild("Entities")
    if not entities then
        return 0, false, "Workspace.Entities missing", "Workspace.Entities"
    end

    local count = 0
    for _, child in ipairs(entities:GetChildren()) do
        if child.Name ~= "Highlight" then
            count += 1
        end
    end

    return count, true, nil, entities:GetFullName()
end

local function classifyPhase(snapshot)
    if snapshot.endScreenVisible then
        return "MATCH_END"
    end

    if not snapshot.mapExists then
        return "TRANSITION_OR_LOBBY"
    end

    if snapshot.placedUnits > 0 then
        return "IN_MATCH_WITH_UNITS"
    end

    if snapshot.entities > 0 then
        return "IN_MATCH_WITH_ENEMIES"
    end

    if snapshot.mapName ~= DEFAULT_MAP_NAME then
        return "MATCH_READY_OR_EMPTY"
    end

    return "UNKNOWN"
end

local function buildDecisionFields(snapshot)
    local isTransitioning = (not snapshot.mapExists) or snapshot.phase == "TRANSITION_OR_LOBBY"
    local canRetry = snapshot.endScreenVisible == true
    local canStartMacro = snapshot.endScreenVisible == false
        and snapshot.mapName ~= DEFAULT_MAP_NAME
        and (tonumber(snapshot.placedUnits) or 0) == 0

    local reason = "ready"
    if snapshot.endScreenVisible then
        reason = "end screen visible"
    elseif snapshot.mapName == DEFAULT_MAP_NAME then
        reason = snapshot.mapNameReason or "map name unknown"
    elseif (tonumber(snapshot.placedUnits) or 0) > 0 then
        reason = "placed units already exist"
    elseif isTransitioning then
        reason = "transition or lobby"
    end

    snapshot.canStartMacro = canStartMacro
    snapshot.canRetry = canRetry
    snapshot.isTransitioning = isTransitioning
    snapshot.reason = reason
end

local function makeSnapshot()
    local mapState = readMapState()
    local outcomeState = readEndScreenState()
    local placedUnits, placedUnitsReason = countPlacedUnits()
    local entities, entitiesExists, entitiesReason, entitiesPath = countActiveEntities()

    local snapshot = {
        version = VERSION,
        timestampUtc = os.date("!%Y-%m-%dT%H:%M:%SZ"),

        mapExists = mapState.mapExists,
        mapName = mapState.mapName,
        mapNameReason = mapState.mapNameReason,
        mapPath = mapState.mapPath,
        mapNamePath = mapState.mapNamePath,

        endScreenVisible = outcomeState.endScreenVisible,
        outcomeText = outcomeState.outcomeText,
        outcomePath = outcomeState.outcomePath,
        outcomeReason = outcomeState.outcomeReason,
        endScreenSource = outcomeState.endScreenSource,

        placedUnits = placedUnits,
        placedUnitsReason = placedUnitsReason,

        entities = entities,
        entitiesExists = entitiesExists,
        entitiesReason = entitiesReason,
        entitiesPath = entitiesPath,
    }

    snapshot.phase = classifyPhase(snapshot)
    buildDecisionFields(snapshot)
    return snapshot
end

local function signature(snapshot)
    return table.concat({
        tostring(snapshot.phase),
        tostring(snapshot.mapExists),
        tostring(snapshot.mapName),
        tostring(snapshot.endScreenVisible),
        tostring(snapshot.outcomeText),
        tostring(snapshot.placedUnits),
        tostring(snapshot.entities),
        tostring(snapshot.canStartMacro),
        tostring(snapshot.canRetry),
        tostring(snapshot.isTransitioning),
    }, "|")
end

local function snapshotLine(snapshot)
    return string.format(
        "phase=%s | map=%s | mapExists=%s | endScreen=%s | outcome=%s | placedUnits=%d | entities=%d | canStart=%s | canRetry=%s | transitioning=%s | reason=%s",
        tostring(snapshot.phase),
        tostring(snapshot.mapName),
        tostring(snapshot.mapExists),
        tostring(snapshot.endScreenVisible),
        tostring(snapshot.outcomeText or "<none>"),
        tonumber(snapshot.placedUnits) or 0,
        tonumber(snapshot.entities) or 0,
        tostring(snapshot.canStartMacro),
        tostring(snapshot.canRetry),
        tostring(snapshot.isTransitioning),
        tostring(snapshot.reason)
    )
end

local function scanOnce(printAlways)
    scanCount += 1
    lastSnapshot = makeSnapshot()
    lastScanClock = os.clock()
    lastSnapshot.snapshotAgeSeconds = 0
    lastSnapshot.snapshotStale = false

    local currentSignature = signature(lastSnapshot)
    if printAlways or currentSignature ~= lastSignature then
        log(snapshotLine(lastSnapshot))
        lastSignature = currentSignature
    end

    return lastSnapshot
end

local function start()
    if running then
        log("already running")
        return
    end

    running = true
    scanCount = 0
    lastSignature = nil
    log("brain started")

    scanThread = task.spawn(function()
        while running do
            scanOnce(false)
            task.wait(SCAN_INTERVAL)
        end
    end)
end

local function stop()
    if not running then
        log("already stopped")
        return
    end

    running = false
    log("brain stopped")
end

local function status()
    local snapshot = lastSnapshot or scanOnce(false)
    log(string.format("running=%s | scans=%d | %s", tostring(running), scanCount, snapshotLine(snapshot)))
end

local function publicSnapshot()
    if not lastSnapshot then
        scanOnce(false)
    end

    local age = lastScanClock and math.max(0, os.clock() - lastScanClock) or math.huge
    local copy = table.clone(lastSnapshot)
    copy.snapshotAgeSeconds = age
    copy.snapshotStale = age > STALE_AFTER_SECONDS
    copy.brainRunning = running
    return copy
end

local function canStartMacro(expectedMapName)
    local snapshot = publicSnapshot()
    local expectedOk = expectedMapName == nil
        or expectedMapName == ""
        or snapshot.mapName == expectedMapName

    return snapshot.canStartMacro and expectedOk and not snapshot.snapshotStale, snapshot
end

local function printSnapshot()
    local snapshot = scanOnce(true)
    log("mapNamePath=" .. tostring(snapshot.mapNamePath))
    log("outcomePath=" .. tostring(snapshot.outcomePath))
    log("entitiesPath=" .. tostring(snapshot.entitiesPath))
    return snapshot
end

_G.AVBrainStart = start
_G.AVBrainStop = stop
_G.AVBrainStatus = status
_G.AVBrainSnapshot = publicSnapshot
_G.AVBrainCanStartMacro = canStartMacro
_G.AVBrainPrintSnapshot = printSnapshot
_G.AVBrainScanNow = function()
    return scanOnce(true)
end
_G.AVStop = function()
    if type(_G.MacroReaderStop) == "function" then
        pcall(_G.MacroReaderStop)
    end
    if type(_G.AVControllerStop) == "function" then
        pcall(_G.AVControllerStop)
    end
    stop()
end
_G.AVMacroStop = _G.AVStop

log("loaded")

task.defer(start)
