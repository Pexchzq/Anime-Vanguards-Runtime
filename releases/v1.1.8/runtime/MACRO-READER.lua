--[[
    SCRIPT TYPE: MACRO READER / REPLAYER
    VERSION: MACRO-READER V0.3 - CACHED-BRAIN

    Usage:
    1. Put the recorded macro Lua file in Potassium workspace, or use compact JSON from Discord/CDN.
    2. Edit DEFAULT_MACRO_FILE below if needed.
    3. Execute this reader.
    4. Run:
        _G.MacroReaderStart()
        _G.MacroReaderStartFromMapConfig()
        _G.MacroReaderStartFromJson("{...compact json...}")
        _G.MacroReaderStartFromUrl("https://cdn.discordapp.com/attachments/...")
        _G.MacroReaderStop()
        _G.MacroReaderStatus()

    Important:
    - GUIDs from old matches are never used.
    - Render maps placementOrder -> new runtime GUID.
    - Upgrade resolves the current runtime GUID from placementOrder.
    - Steps execute strictly in array order.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local VERSION = "MACRO-READER V0.3 - CACHED-BRAIN"
local DEFAULT_MACRO_FILE = "C:/Users/Siwakan Talasak/AppData/Local/Potassium/workspace/macro_1780459527.lua"
local DEFAULT_MACRO_URL = ""
-- Fallback only. Prefer the unified runtime config so _G.AVMacroConfig is populated there.
local DEFAULT_MAP_MACRO_CONFIG = "C:/Users/Siwakan Talasak/OneDrive/Desktop/anime vanguards/config/AV-RUNTIME-CONFIG V1.0.lua"
local DEFAULT_MAP_NAME = "UNKNOWN_MAP"

-- No automatic timeout:
-- The reader must not skip, fail forward, or continue by itself.
-- If a step is not confirmed, it waits until the expected confirmation appears
-- or until the user manually calls _G.MacroReaderStop().
local VERIFY_TIMEOUT = nil
local POSITION_TOLERANCE = 4
local ACTION_RETRY_INTERVAL = 2.0
local START_READY_STABLE_SECONDS = 2.0
local START_READY_SCAN_INTERVAL = 0.5
-- Recorder-observed Render payload shape:
-- args[2][1] = unitName
-- args[2][2] = tier
-- args[2][3] = Vector3 position
-- args[2][4] = rotation
-- Do not split x/y/z unless a future path-test proves the server accepts it.
local RENDER_POSITION_MODE = "vector3"
local REMOTE_DEBUG = true

local running = false
local waitingForStart = false
local stopRequested = false
local manualStopRequested = false
local mapConfigSupervisorRunning = false
local loadedMacro = nil
local currentStepIndex = 0
local runtimeByPlacementOrder = {}
local knownGuids = {}
local newUnitQueue = {}
local unitObserverConnection = nil
local upgradeConnectionsByGuid = {}
local upgradeLabelConnections = {}
local lastUpgradeByGuid = {}
local brainWarningLogged = false
local MAX_BRAIN_SNAPSHOT_AGE = 3.5
local lastRunResult = "idle"

local loadMacro = nil
local macroSourceLabel = nil
local readBrainSnapshot = nil

local function log(message)
    print("[Reader] " .. tostring(message))
end

local function getUnitEvent()
    local networking = ReplicatedStorage:FindFirstChild("Networking")
    return networking and networking:FindFirstChild("UnitEvent")
end

local function isGuidLike(text)
    return string.match(
        string.lower(text or ""),
        "^[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+$"
    ) ~= nil
end

local function normalizePos(value)
    if typeof(value) == "Vector3" then
        return value
    end

    if typeof(value) == "CFrame" then
        return value.Position
    end

    if type(value) == "string" then
        local x, y, z = string.match(value, "([%-%.%d]+),%s*([%-%.%d]+),%s*([%-%.%d]+)")
        if x then
            return Vector3.new(tonumber(x), tonumber(y), tonumber(z))
        end
    end

    return value
end

local function posToString(value)
    value = normalizePos(value)
    if typeof(value) == "Vector3" then
        return string.format("Vector3.new(%.3f, %.3f, %.3f)", value.X, value.Y, value.Z)
    end
    return tostring(value)
end

local function dumpTable(value)
    if type(value) ~= "table" then
        return tostring(value)
    end

    local parts = {}
    for key, item in pairs(value) do
        table.insert(parts, "[" .. tostring(key) .. "]=" .. tostring(item))
    end
    table.sort(parts)
    return "{ " .. table.concat(parts, ", ") .. " }"
end

local function positionDistance(a, b)
    a = normalizePos(a)
    b = normalizePos(b)
    if typeof(a) ~= "Vector3" or typeof(b) ~= "Vector3" then
        return nil
    end
    return (a - b).Magnitude
end

local function trimLower(text)
    text = tostring(text or "")
    text = string.gsub(text, "^%s*(.-)%s*$", "%1")
    return string.lower(text)
end

local function parseUpgradeLevel(text)
    return tonumber(string.match(tostring(text or ""), "^%[(%d+)%]%s*Upgrade!$"))
end

local function getUnitNameFromUpgradeInterface(guid)
    local gui = player:FindFirstChild("PlayerGui")
    local upgradeInterfaces = gui and gui:FindFirstChild("UpgradeInterfaces")
    local frame = upgradeInterfaces and upgradeInterfaces:FindFirstChild(guid)
    local main = frame and frame:FindFirstChild("Main")
    local leftSide = main and main:FindFirstChild("LeftSide")
    local unitTemplate = leftSide and leftSide:FindFirstChild("UnitTemplate")
    local templateMain = unitTemplate and unitTemplate:FindFirstChild("Main")
    local unitName = templateMain and templateMain:FindFirstChild("UnitName")
    return unitName and unitName.Text or nil
end

local function disconnectAllUpgradeObservers()
    for guid, connections in pairs(upgradeConnectionsByGuid) do
        for _, connection in ipairs(connections) do
            connection:Disconnect()
        end
        upgradeConnectionsByGuid[guid] = nil
    end

    for label, connection in pairs(upgradeLabelConnections) do
        connection:Disconnect()
        upgradeLabelConnections[label] = nil
    end
end

local function noteUpgradeText(guid, label)
    if not label or not label:IsA("TextLabel") then
        return
    end

    local level = parseUpgradeLevel(label.Text)
    if not level then
        return
    end

    lastUpgradeByGuid[guid] = math.max(lastUpgradeByGuid[guid] or 0, level)
    log(string.format("upgrade confirmed | guid=%s | level=%d", guid, level))
end

local function watchUpgradeLabel(guid, label)
    if not label or not label:IsA("TextLabel") then
        return
    end

    noteUpgradeText(guid, label)

    if upgradeLabelConnections[label] then
        upgradeLabelConnections[label]:Disconnect()
    end

    upgradeLabelConnections[label] = label:GetPropertyChangedSignal("Text"):Connect(function()
        noteUpgradeText(guid, label)
    end)
end

local function watchUpgradeText(guid, upgradeText)
    if not upgradeText then
        return
    end

    watchUpgradeLabel(guid, upgradeText:FindFirstChild("Label"))

    local childAdded = upgradeText.ChildAdded:Connect(function(child)
        if child.Name == "Label" and child:IsA("TextLabel") then
            watchUpgradeLabel(guid, child)
        end
    end)

    upgradeConnectionsByGuid[guid] = upgradeConnectionsByGuid[guid] or {}
    table.insert(upgradeConnectionsByGuid[guid], childAdded)
end

local function watchUnitUpgradeEvents(unit)
    if not unit or not unit:IsA("Model") or not isGuidLike(unit.Name) then
        return
    end

    local guid = unit.Name
    if upgradeConnectionsByGuid[guid] then
        return
    end

    upgradeConnectionsByGuid[guid] = {}

    local existing = unit:FindFirstChild("UpgradeText")
    if existing then
        watchUpgradeText(guid, existing)
    end

    local descendantAdded = unit.DescendantAdded:Connect(function(descendant)
        if descendant.Name == "UpgradeText" then
            watchUpgradeText(guid, descendant)
        elseif descendant.Name == "Label" and descendant.Parent and descendant.Parent.Name == "UpgradeText" then
            watchUpgradeLabel(guid, descendant)
        end
    end)

    table.insert(upgradeConnectionsByGuid[guid], descendantAdded)
end

local function connectUnitObserver()
    if unitObserverConnection then
        unitObserverConnection:Disconnect()
        unitObserverConnection = nil
    end

    table.clear(knownGuids)
    table.clear(newUnitQueue)

    local units = Workspace:FindFirstChild("Units")
    if not units then
        log("unit observer waiting | reason=Workspace.Units missing")
        return false
    end
    for _, child in ipairs(units:GetChildren()) do
        if child:IsA("Model") and isGuidLike(child.Name) then
            knownGuids[child.Name] = true
            watchUnitUpgradeEvents(child)
        end
    end

    unitObserverConnection = units.ChildAdded:Connect(function(unit)
        if unit:IsA("Model") and isGuidLike(unit.Name) then
            watchUnitUpgradeEvents(unit)
            if not knownGuids[unit.Name] then
                knownGuids[unit.Name] = true
                table.insert(newUnitQueue, unit)
            end
        end
    end)

    return true
end

local function buildRenderPayload(step)
    local position = normalizePos(step.position)
    local rotation = step.rotation or 0

    if typeof(position) ~= "Vector3" then
        error("Render step position is not Vector3: " .. tostring(step.position))
    end

    if RENDER_POSITION_MODE == "vector3" then
        return {
            [1] = step.unitName,
            [2] = step.tier,
            [3] = position,
            [4] = rotation,
        }
    end

    return {
        [1] = step.unitName,
        [2] = step.tier,
        [3] = position.X,
        [4] = position.Y,
        [5] = position.Z,
        [6] = rotation,
    }
end

local function requestRender(step)
    local payload = buildRenderPayload(step)
    local options = {
        SlotIndex = step.slotIndex,
    }

    if REMOTE_DEBUG then
        log("REMOTE Render action=Render")
        log("REMOTE Render payload=" .. dumpTable(payload))
        log("REMOTE Render options=" .. dumpTable(options))
    end

    local unitEvent = getUnitEvent()
    if not unitEvent then
        error("UnitEvent missing")
    end
    unitEvent:FireServer("Render", payload, options)
end

local function requestUpgrade(runtime)
    if REMOTE_DEBUG then
        log("REMOTE Upgrade action=Upgrade")
        log("REMOTE Upgrade guid=" .. tostring(runtime.runtimeGuid))
    end

    local unitEvent = getUnitEvent()
    if not unitEvent then
        error("UnitEvent missing")
    end
    unitEvent:FireServer("Upgrade", runtime.runtimeGuid)
end

local function findMatchingNewUnit(step)
    local expectedPosition = normalizePos(step.position)

    for index = 1, #newUnitQueue do
        local unit = newUnitQueue[index]
        if unit and unit.Parent then
            local basePosition = normalizePos(unit:GetAttribute("BasePosition"))
            local distance = positionDistance(basePosition, expectedPosition)

            if distance and distance <= POSITION_TOLERANCE then
                table.remove(newUnitQueue, index)
                return unit, string.format("BasePosition distance %.3f", distance)
            end
        end
    end

    return nil, "no new Workspace.Units GUID matched expected position"
end

local function waitForRenderConfirmation(step)
    local nextAttemptAt = 0
    local attempts = 0

    while not stopRequested do
        local state = readBrainSnapshot()
        if state.snapshotStale == true or (tonumber(state.snapshotAgeSeconds) or 0) > MAX_BRAIN_SNAPSHOT_AGE then
            task.wait(START_READY_SCAN_INTERVAL)
            continue
        end
        if state.endScreenVisible == true and state.phase == "MATCH_END" then
            return nil, "MATCH_ENDED"
        end

        if os.clock() >= nextAttemptAt then
            attempts += 1
            log(string.format("Render attempt #%d | placementOrder=%s", attempts, tostring(step.placementOrder)))
            requestRender(step)
            nextAttemptAt = os.clock() + ACTION_RETRY_INTERVAL
        end

        local unit, reason = findMatchingNewUnit(step)
        if unit then
            local guid = unit.Name
            local resolvedName = getUnitNameFromUpgradeInterface(guid) or step.unitName

            if trimLower(resolvedName) ~= trimLower(step.unitName) then
                return nil, string.format("unit name mismatch expected=%s observed=%s", tostring(step.unitName), tostring(resolvedName))
            end

            return {
                runtimeGuid = guid,
                unitName = resolvedName,
                position = normalizePos(step.position),
                slotIndex = step.slotIndex,
                upgradeLevel = 0,
            }, reason
        end

        task.wait(0.05)
    end

    return nil, "render confirmation stopped by user"
end

local function waitForUpgradeConfirmation(runtime, expectedLevel)
    local nextAttemptAt = 0
    local attempts = 0

    while not stopRequested do
        local state = readBrainSnapshot()
        if state.snapshotStale == true or (tonumber(state.snapshotAgeSeconds) or 0) > MAX_BRAIN_SNAPSHOT_AGE then
            task.wait(START_READY_SCAN_INTERVAL)
            continue
        end
        if state.endScreenVisible == true and state.phase == "MATCH_END" then
            return false, "MATCH_ENDED"
        end

        if (lastUpgradeByGuid[runtime.runtimeGuid] or 0) >= expectedLevel then
            runtime.upgradeLevel = expectedLevel
            return true
        end

        if os.clock() >= nextAttemptAt then
            attempts += 1
            log(string.format(
                "Upgrade attempt #%d | guid=%s | expectedLevel=%s | lastLevel=%s",
                attempts,
                runtime.runtimeGuid,
                tostring(expectedLevel),
                tostring(lastUpgradeByGuid[runtime.runtimeGuid] or 0)
            ))
            requestUpgrade(runtime)
            nextAttemptAt = os.clock() + ACTION_RETRY_INTERVAL
        end

        if (lastUpgradeByGuid[runtime.runtimeGuid] or 0) >= expectedLevel then
            runtime.upgradeLevel = expectedLevel
            return true
        end
        task.wait(0.05)
    end

    return false
end

local function startsWith(text, prefix)
    return string.sub(tostring(text or ""), 1, #prefix) == prefix
end

local function stripBomAndTrim(text)
    text = tostring(text or "")
    text = string.gsub(text, "^\239\187\191", "")
    return string.match(text, "^%s*(.-)%s*$") or text
end

local function isUrl(source)
    source = tostring(source or "")
    return startsWith(source, "http://") or startsWith(source, "https://")
end

local function readTextFile(path)
    if typeof(readfile) ~= "function" then
        return nil, "readfile is unavailable for JSON files; use _G.MacroReaderStartFromJson(jsonText) or Lua loadfile"
    end

    local ok, content = pcall(readfile, path)
    if not ok then
        return nil, content
    end
    return content, nil
end

local function fileExists(path)
    if typeof(isfile) == "function" then
        local ok, exists = pcall(isfile, path)
        if ok then
            return exists
        end
    end

    if typeof(readfile) == "function" then
        local ok = pcall(readfile, path)
        return ok
    end

    local loader = loadfile(path)
    return loader ~= nil
end

local function readCurrentMapName()
    local map = Workspace:FindFirstChild("Map")
    if not map then
        return DEFAULT_MAP_NAME, "Workspace.Map missing"
    end

    local value = map:GetAttribute("MapName")
    if value == nil or tostring(value) == "" then
        return DEFAULT_MAP_NAME, "Workspace.Map MapName missing"
    end

    return tostring(value), nil
end

local function countPlacedUnits()
    local units = Workspace:FindFirstChild("Units")
    if not units then
        return 0
    end

    local count = 0
    for _, child in ipairs(units:GetChildren()) do
        if child:IsA("Model") and isGuidLike(child.Name) then
            count += 1
        end
    end
    return count
end

readBrainSnapshot = function()
    if type(_G.AVBrainSnapshot) == "function" then
        local ok, snapshot = pcall(_G.AVBrainSnapshot)
        if ok and type(snapshot) == "table" then
            return snapshot
        end
        if not brainWarningLogged then
            log("Brain snapshot failed; install/run MACRO-BRAIN.lua first for accurate state")
            brainWarningLogged = true
        end
    end

    if not brainWarningLogged then
        log("Brain missing; using minimum reader fallback without end-screen fallback scan")
        brainWarningLogged = true
    end
    local mapName, mapErr = readCurrentMapName()
    return {
        phase = "UNKNOWN",
        mapName = mapName,
        mapNameReason = mapErr,
        endScreenVisible = false,
        outcomeText = nil,
        outcomePath = nil,
        placedUnits = countPlacedUnits(),
        entities = nil,
        canStartMacro = mapName ~= DEFAULT_MAP_NAME and countPlacedUnits() == 0,
        reason = "reader fallback; Brain missing",
        source = "reader-fallback",
    }
end

local function stateLine(state)
    return string.format(
        "phase=%s | map=%s | endScreen=%s | outcome=%s | placedUnits=%s | entities=%s",
        tostring(state.phase),
        tostring(state.mapName),
        tostring(state.endScreenVisible),
        tostring(state.outcomeText or "<none>"),
        tostring(state.placedUnits),
        tostring(state.entities or "<unknown>")
    )
end

local function waitForMacroStartReady(expectedMapName, requireEmptyUnits)
    local stableSince = nil
    local lastLogged = ""

    while not stopRequested do
        local state = readBrainSnapshot()
        local fresh = state.snapshotStale ~= true
            and (tonumber(state.snapshotAgeSeconds) or 0) <= MAX_BRAIN_SNAPSHOT_AGE
        local readyFromBrain = fresh and state.mapName == expectedMapName and state.endScreenVisible == false
        local placedOk = (not requireEmptyUnits) or ((tonumber(state.placedUnits) or 0) == 0)
        local ready = readyFromBrain and placedOk

        local line = stateLine(state)
        if line ~= lastLogged then
            log("start gate | " .. line .. " | expectedMap=" .. tostring(expectedMapName) .. " | ready=" .. tostring(ready))
            lastLogged = line
        end

        if ready then
            stableSince = stableSince or os.clock()
            if os.clock() - stableSince >= START_READY_STABLE_SECONDS then
                log("start gate passed | stableSeconds=" .. tostring(START_READY_STABLE_SECONDS))
                return true
            end
        else
            stableSince = nil
        end

        task.wait(START_READY_SCAN_INTERVAL)
    end

    return false, "stopped while waiting for start gate"
end

local function normalizeMapMacroConfig(config)
    if type(config) ~= "table" then
        return nil, "config is not a table"
    end

    config.Maps = config.Maps or {}
    config.MacroSources = config.MacroSources or {}
    config.DefaultMapName = config.DefaultMapName or DEFAULT_MAP_NAME
    return config, nil
end

local function loadMapMacroConfig(path)
    if not path and type(_G.AVMacroConfig) == "table" then
        return normalizeMapMacroConfig(_G.AVMacroConfig)
    end

    path = path or DEFAULT_MAP_MACRO_CONFIG

    local loader, loadErr = loadfile(path)
    if not loader then
        if not path and type(_G.AVMacroConfig) ~= "table" then
            return nil, "runtime _G.AVMacroConfig missing and fallback config load failed: " .. tostring(loadErr)
        end
        return nil, loadErr
    end

    local ok, config = pcall(loader)
    if not ok then
        return nil, config
    end

    return normalizeMapMacroConfig(config)
end

local function resolveMacroSourceForMap(config, currentMapName)
    for index, entry in ipairs(config.MacroSources or {}) do
        if entry.Enabled ~= false then
            local source = entry.Json or entry.InlineJson or entry.Source or entry.JsonPath or entry.Url
            if source and source ~= "" then
                local macro, macroErr = loadMacro(source)
                if not macro then
                    log("SKIP macro source #" .. tostring(index) .. " load failed | source=" .. macroSourceLabel(source) .. " | reason=" .. tostring(macroErr))
                    continue
                end

                local recordedMapName = macro.Metadata and macro.Metadata.mapName
                if recordedMapName == currentMapName then
                    return source, macro, entry
                end

                log("SKIP macro source #" .. tostring(index) .. " map mismatch | current=" .. tostring(currentMapName) .. " | macro=" .. tostring(recordedMapName or "<missing>"))
            end
        end
    end

    local legacyEntry = config.Maps and config.Maps[currentMapName]
    if legacyEntry and legacyEntry.Enabled ~= false then
        local source = legacyEntry.Json or legacyEntry.InlineJson or legacyEntry.JsonPath or legacyEntry.Source or legacyEntry.Url
        if source and source ~= "" then
            local macro, macroErr = loadMacro(source)
            if not macro then
                return nil, nil, nil, "legacy map source load failed: " .. tostring(macroErr)
            end
            return source, macro, legacyEntry
        end
    end

    return nil, nil, nil, "no enabled macro source matched mapName=" .. tostring(currentMapName)
end

local function fetchUrl(url)
    local requestFn = nil
    if syn and syn.request then
        requestFn = syn.request
    elseif http_request then
        requestFn = http_request
    elseif request then
        requestFn = request
    end

    if requestFn then
        local ok, response = pcall(requestFn, {
            Url = url,
            Method = "GET",
        })
        if not ok then
            return nil, response
        end
        if type(response) == "table" then
            if response.StatusCode and response.StatusCode >= 400 then
                return nil, "HTTP " .. tostring(response.StatusCode)
            end
            return response.Body or response.body or "", nil
        end
        return tostring(response or ""), nil
    end

    if typeof(game.HttpGet) == "function" then
        local ok, body = pcall(function()
            return game:HttpGet(url)
        end)
        if ok then
            return body, nil
        end
        return nil, body
    end

    return nil, "no HTTP fetch function available"
end

local function compactPosition(value)
    if typeof(value) == "Vector3" then
        return value
    end
    if type(value) == "table" then
        return Vector3.new(tonumber(value[1]) or 0, tonumber(value[2]) or 0, tonumber(value[3]) or 0)
    end
    return normalizePos(value)
end

local function expandMacroStep(step)
    if type(step) ~= "table" then
        return nil, "step is not a table"
    end

    if step.action == "Render" or step.action == "Upgrade" then
        if step.action == "Render" then
            step.position = compactPosition(step.position)
            step.rotation = step.rotation or 0
        end
        return step, nil
    end

    if step.a == "R" then
        return {
            action = "Render",
            placementOrder = step.o,
            unitName = step.u,
            tier = step.t,
            position = compactPosition(step.p),
            rotation = step.r or 0,
            slotIndex = step.s,
        }, nil
    end

    if step.a == "U" then
        return {
            action = "Upgrade",
            placementOrder = step.o,
            upgradeLevel = step.l,
        }, nil
    end

    return nil, "unknown compact action " .. tostring(step.a or step.action)
end

local function normalizeMacro(macro)
    if type(macro) ~= "table" then
        return nil, "macro is not a table"
    end

    local rawSteps = macro.steps or macro
    if type(rawSteps) ~= "table" then
        return nil, "macro steps are missing"
    end

    local steps = {}
    for index, rawStep in ipairs(rawSteps) do
        local step, err = expandMacroStep(rawStep)
        if not step then
            return nil, "step " .. tostring(index) .. ": " .. tostring(err)
        end
        table.insert(steps, step)
    end

    steps.Metadata = {
        format = macro.format,
        version = macro.version,
        recorder = macro.recorder,
        generatedAt = macro.generatedAt,
        mapName = macro.mapName,
        mapNamePath = macro.mapNamePath,
        identity = macro.identity,
    }

    return steps, nil
end

local function loadMacroFromJsonText(jsonText)
    jsonText = stripBomAndTrim(jsonText)
    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(jsonText)
    end)
    if not ok then
        return nil, decoded
    end
    return normalizeMacro(decoded)
end

function loadMacro(path)
    local source = stripBomAndTrim(path)

    if startsWith(source, "{") or startsWith(source, "[") then
        return loadMacroFromJsonText(source)
    end

    if isUrl(source) then
        local body, fetchErr = fetchUrl(source)
        if not body then
            return nil, fetchErr
        end
        return loadMacroFromJsonText(body)
    end

    if string.lower(string.sub(source, -5)) == ".json" then
        local content, readErr = readTextFile(source)
        if not content then
            return nil, readErr
        end
        return loadMacroFromJsonText(content)
    end

    local loader, err = loadfile(source)
    if not loader then
        return nil, err
    end

    local ok, macroOrErr = pcall(loader)
    if not ok then
        return nil, macroOrErr
    end

    return normalizeMacro(macroOrErr)
end

function macroSourceLabel(source)
    source = stripBomAndTrim(source)
    if startsWith(source, "{") or startsWith(source, "[") then
        return "inline-json"
    end
    if isUrl(source) then
        return "url:" .. source
    end
    return source
end

local function executeStep(stepIndex, step)
    if step.action == "Render" then
        log(string.format(
            "[STEP %02d] Render placementOrder=%s unit=%s slot=%s pos=%s",
            stepIndex,
            tostring(step.placementOrder),
            tostring(step.unitName),
            tostring(step.slotIndex),
            posToString(step.position)
        ))

        local runtime, reason = waitForRenderConfirmation(step)
        if not runtime then
            return false, reason
        end

        runtimeByPlacementOrder[step.placementOrder] = runtime
        log(string.format(
            "[STEP %02d] Render verified | placementOrder=%s | guid=%s | %s",
            stepIndex,
            tostring(step.placementOrder),
            runtime.runtimeGuid,
            reason
        ))
        return true
    end

    if step.action == "Upgrade" then
        log(string.format(
            "[STEP %02d] Upgrade placementOrder=%s unit=%s level=%s",
            stepIndex,
            tostring(step.placementOrder),
            tostring(step.unitName),
            tostring(step.upgradeLevel)
        ))

        local runtime = runtimeByPlacementOrder[step.placementOrder]
        if not runtime then
            return false, "missing runtime GUID for placementOrder " .. tostring(step.placementOrder)
        end

        local upgradeOk, upgradeReason = waitForUpgradeConfirmation(runtime, step.upgradeLevel)
        if not upgradeOk then
            if upgradeReason == "MATCH_ENDED" then
                return false, "MATCH_ENDED"
            end
            return false, string.format(
                "upgrade confirmation stopped by user | guid=%s | expectedLevel=%s | lastLevel=%s",
                runtime.runtimeGuid,
                tostring(step.upgradeLevel),
                tostring(lastUpgradeByGuid[runtime.runtimeGuid] or 0)
            )
        end

        log(string.format(
            "[STEP %02d] Upgrade verified | placementOrder=%s | guid=%s | level=%s",
            stepIndex,
            tostring(step.placementOrder),
            runtime.runtimeGuid,
            tostring(step.upgradeLevel)
        ))
        return true
    end

    return false, "unknown action " .. tostring(step.action)
end

local function runMacro(source)
    if running then
        log("already running")
        return
    end

    local macro, err = loadMacro(source)
    if not macro then
        log("load failed: " .. tostring(err))
        return
    end

    loadedMacro = macro
    running = true
    stopRequested = false
    lastRunResult = "running"
    currentStepIndex = 0
    runtimeByPlacementOrder = {}
    lastUpgradeByGuid = {}
    disconnectAllUpgradeObservers()

    log(string.format("started | source=%s | steps=%d", macroSourceLabel(source), #macro))

    task.spawn(function()
        while not stopRequested and not connectUnitObserver() do
            task.wait(ACTION_RETRY_INTERVAL)
        end

        for index, step in ipairs(macro) do
            if stopRequested then
                log("stopped by request")
                break
            end

            local state = readBrainSnapshot()
            if state.endScreenVisible then
                log("match outcome detected; stopping and resetting step pointer | " .. stateLine(state) .. " | path=" .. tostring(state.outcomePath))
                stopRequested = true
                lastRunResult = "match_ended"
                currentStepIndex = 0
                break
            end

            currentStepIndex = index
            local ok, reason = executeStep(index, step)
            if not ok then
                if reason == "MATCH_ENDED" then
                    log(string.format("[STEP %02d] match ended; resetting for next round", index))
                    lastRunResult = "match_ended"
                    currentStepIndex = 0
                else
                    log(string.format("[STEP %02d] failed: %s", index, tostring(reason)))
                    lastRunResult = "step_failed"
                end
                stopRequested = true
                break
            end

            task.wait(0.15)
        end

        running = false
        if unitObserverConnection then
            unitObserverConnection:Disconnect()
            unitObserverConnection = nil
        end
        disconnectAllUpgradeObservers()

        if stopRequested then
            if lastRunResult == "running" then
                lastRunResult = "manual_stop"
            end
            log("finished with stop/failure")
        else
            lastRunResult = "completed_steps"
            log("finished successfully")
        end
    end)
end

local function waitForEndScreenBeforeNextRound()
    local lastLogged = ""

    while not manualStopRequested do
        local state = readBrainSnapshot()
        local line = stateLine(state)
        if line ~= lastLogged then
            log("round re-arm | waiting for EndScreen | " .. line)
            lastLogged = line
        end

        if state.endScreenVisible == true then
            log("round re-arm | EndScreen detected; waiting for next start gate")
            return true
        end

        task.wait(START_READY_SCAN_INTERVAL)
    end

    return false
end

local function macroReaderStartFromMapConfig(configPath)
    if running or waitingForStart or mapConfigSupervisorRunning then
        log("already running")
        return
    end

    stopRequested = false
    manualStopRequested = false

    local config, configErr = loadMapMacroConfig(configPath)
    if not config then
        log("FAIL map config load failed: " .. tostring(configErr))
        return
    end

    local mapName, mapErr = readCurrentMapName()
    if mapErr then
        log("map name fallback used: " .. tostring(mapErr) .. " | value=" .. tostring(mapName))
    end

    local source, macro, entry, resolveErr = resolveMacroSourceForMap(config, mapName)
    if not source then
        log("FAIL macro source resolve failed | " .. tostring(resolveErr))
        return
    end

    local recordedMapName = macro.Metadata and macro.Metadata.mapName
    if recordedMapName and recordedMapName ~= "" and recordedMapName ~= mapName then
        log("FAIL macro mapName mismatch | current=" .. tostring(mapName) .. " | macro=" .. tostring(recordedMapName))
        return
    end

    mapConfigSupervisorRunning = true
    log("PASS map config | continuous replay supervisor started | mapName=" .. tostring(mapName) .. " | source=" .. tostring(source))
    task.spawn(function()
        local firstRound = true

        while not manualStopRequested do
            if not firstRound then
                if lastRunResult == "match_ended" then
                    log("round re-arm | previous round already ended; waiting for next start gate")
                else
                    if not waitForEndScreenBeforeNextRound() then
                        break
                    end
                end
            end

            stopRequested = false
            waitingForStart = true
            local ok, reason = waitForMacroStartReady(mapName, config.RequireEmptyPlacedUnitsOnStart)
            waitingForStart = false

            if not ok or manualStopRequested then
                log("start gate stopped: " .. tostring(reason))
                break
            end

            runMacro(source)
            while running and not manualStopRequested do
                task.wait(START_READY_SCAN_INTERVAL)
            end

            firstRound = false
        end

        waitingForStart = false
        mapConfigSupervisorRunning = false
        log("continuous replay supervisor stopped")
    end)
end

local function macroReaderStart(path)
    local source = path or DEFAULT_MACRO_URL
    if not source or source == "" then
        source = DEFAULT_MACRO_FILE
    end
    runMacro(source)
end

local function macroReaderStartFromJson(jsonText)
    runMacro(jsonText)
end

local function macroReaderStartFromUrl(url)
    runMacro(url)
end

local function macroReaderStop()
    manualStopRequested = true
    stopRequested = true
    log("stop requested")
end

local function macroReaderStatus()
    log(string.format(
        "running=%s | waitingForStart=%s | supervisor=%s | currentStep=%d | loadedSteps=%d | lastRun=%s",
        tostring(running),
        tostring(waitingForStart),
        tostring(mapConfigSupervisorRunning),
        currentStepIndex,
        loadedMacro and #loadedMacro or 0,
        tostring(lastRunResult)
    ))
end

local function macroReaderTestFirstRender(path)
    local macro, err = loadMacro(path or DEFAULT_MACRO_FILE)
    if not macro then
        log("load failed: " .. tostring(err))
        return
    end

    for index, step in ipairs(macro) do
        if step.action == "Render" then
            log(string.format("test first Render step=%d unit=%s tier=%s slot=%s pos=%s", index, tostring(step.unitName), tostring(step.tier), tostring(step.slotIndex), posToString(step.position)))
            requestRender(step)
            return
        end
    end

    log("no Render step found in macro")
end

_G.MacroReaderStart = macroReaderStart
_G.MacroReaderStartFromMapConfig = macroReaderStartFromMapConfig
_G.MacroReaderStartFromJson = macroReaderStartFromJson
_G.MacroReaderStartFromUrl = macroReaderStartFromUrl
_G.MacroReaderStop = macroReaderStop
_G.MacroReaderStatus = macroReaderStatus
_G.MacroReaderTestFirstRender = macroReaderTestFirstRender
_G.AVStop = function()
    macroReaderStop()
    if type(_G.AVControllerStop) == "function" then
        pcall(_G.AVControllerStop)
    end
    if type(_G.AVBrainStop) == "function" then
        pcall(_G.AVBrainStop)
    end
end
_G.AVMacroStop = _G.AVStop

log("loaded | waiting for matching map")

task.defer(macroReaderStartFromMapConfig)
