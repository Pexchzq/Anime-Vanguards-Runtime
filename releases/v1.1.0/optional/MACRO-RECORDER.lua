--[[
    SCRIPT TYPE: MACRO RECORDER
    VERSION: MACRO-RECORDER V1.4 - SINGLETON-HOOK

    Core fix:
    - GUID is runtime-only. It is never used as the permanent identity in the saved macro.
    - The saved macro identifies units by placementOrder + unitName + position + slotIndex.
    - Successful upgrade events are detected from:
        Workspace.Units.<GUID>.UpgradeText.Label.Text
      but are saved against placementOrder, not GUID.

    Why this matters:
    - Workspace.Units.<GUID> changes every match / placement.
    - Saving GUID directly makes replay/readers brittle.
    - During recording, GUID is useful only to correlate temporary Workspace events.

    Commands:
    - _G.MacroStart()
    - _G.MacroStop()
    - _G.MacroStatus()
    - _G.MacroClear()

    Output:
    - Copies compact JSON to clipboard on _G.MacroStop().
    - Does not save macro files by default. Set SAVE_LUA_FILE = true if a local backup is needed.
    - Use _G.MacroCopyLastJson() to copy the latest compact JSON again.

    Reader implementation contract:
    - The reader must execute macro steps strictly in array order.
    - The reader must not skip a failed or unconfirmed step and continue blindly.
      If a Render or Upgrade step cannot be verified, pause/stop and report the failure.
    - The reader must build its own runtime mapping while replaying:
        runtimeByPlacementOrder[placementOrder] = {
            runtimeGuid = "<new GUID from this match>",
            unitName = step.unitName,
            position = step.position,
            slotIndex = step.slotIndex,
            upgradeLevel = 0,
        }
    - For Render steps, after the reader performs/requests placement, it must wait for a new
      Workspace.Units.<GUID> model and verify it matches the step identity before moving on:
        1. placementOrder is the sequence number from the macro.
        2. unitName should match if a reliable name source is available.
        3. BasePosition should be near step.position within tolerance.
        4. slotIndex is an intent/check value; it is not expected to appear in Workspace.
    - For Upgrade steps, the reader must resolve the current match GUID from:
        runtimeByPlacementOrder[step.placementOrder].runtimeGuid
      and then wait for the success signal:
        Workspace.Units.<runtimeGuid>.UpgradeText.Label.Text == "[N] Upgrade!"
      where N == step.upgradeLevel.
    - UpgradeText is temporary. The reader must listen for DescendantAdded/Text changes and
      cache the last confirmed upgradeLevel per placementOrder. Do not rely on UpgradeText
      being present during a later scan.
    - A missing UpgradeText is not proof of failure; it only means no success event is visible
      at that instant. Failure is timeout/no confirmation after an attempted action.
    - GUIDs saved in old macro files must be ignored for identity. Treat GUID as runtime-only.
    - Stable macro identity is:
        placementOrder + unitName + position + slotIndex
    - If multiple units have the same unitName, placementOrder is the primary identity and
      position is the sanity check.
    - Do not reorder actions by type. Example: Render, Upgrade, Render must stay exactly that.

    Step-by-step reader build guide:
    1. Load the generated macro file.
       - The file returns a Lua array named macro.
       - Each entry is one action in exact replay order.
       - Do not sort, group, deduplicate, or reorder the array.

    2. Initialize reader runtime state.
       - Create a table:
           runtimeByPlacementOrder = {}
       - This table exists only during the current replay run.
       - It maps stable macro placementOrder to the new Workspace GUID created in this match.

    3. Start a Workspace.Units observer before replaying the first action.
       - Listen to:
           Workspace.Units.ChildAdded
       - Accept only Model children whose Name looks like a GUID.
       - For every new unit model, read:
           unit.Name
           unit:GetAttribute("BasePosition")
           unit:GetAttribute("BaseUnitCFrame")
       - Optional name check can use UI if available, but UI must not be the only verifier.

    4. Execute each macro step in array order.
       - Use a for loop:
           for stepIndex, step in ipairs(macro) do
               execute step
               verify step before continuing
           end
       - If verification fails, stop/pause the reader and report the exact stepIndex.
       - Never continue to the next step after an unverified action.

    5. Render step handling.
       - A Render step means the reader should place/request one unit matching:
           step.unitName
           step.tier
           step.position
           step.slotIndex
       - After the placement attempt, wait for a new Workspace.Units.<GUID> model.
       - Verify the new model:
           a. BasePosition is near step.position within tolerance.
           b. If a reliable name source is available, unitName matches step.unitName.
           c. The step was not already mapped.
       - On success, create:
           runtimeByPlacementOrder[step.placementOrder] = {
               runtimeGuid = newGuid,
               unitName = step.unitName,
               position = step.position,
               slotIndex = step.slotIndex,
               upgradeLevel = 0,
           }
       - Only after this mapping exists may the reader continue to the next macro step.

    6. Upgrade event observer setup.
       - For every mapped runtime GUID, listen under:
           Workspace.Units.<runtimeGuid>
       - Watch DescendantAdded for:
           UpgradeText
           UpgradeText.Label
       - Also watch Label:GetPropertyChangedSignal("Text").
       - Parse successful upgrade text with:
           local n = tonumber(text:match("^%[(%d+)%]%s*Upgrade!$"))
       - If n exists, it confirms the unit reached upgrade level n.

    7. Upgrade step handling.
       - An Upgrade step references placementOrder, not GUID.
       - Resolve the current unit:
           local runtime = runtimeByPlacementOrder[step.placementOrder]
       - If runtime is missing, stop immediately. The reader lost track of the unit.
       - Attempt/request the upgrade for runtime.runtimeGuid according to the reader's own
         implementation.
       - Wait until the observer sees:
           Workspace.Units.<runtimeGuid>.UpgradeText.Label.Text == "[" .. step.upgradeLevel .. "] Upgrade!"
       - On success:
           runtime.upgradeLevel = step.upgradeLevel
       - On timeout/no confirmation:
           stop/pause and report this Upgrade step as failed.

    8. Handling UpgradeText correctly.
       - UpgradeText is a temporary success effect.
       - It may not exist before or after the upgrade event.
       - Therefore, do not scan once later and expect it to be present.
       - The reader must listen for creation/text changes while the upgrade is being attempted.
       - Cache the latest confirmed upgrade level in runtimeByPlacementOrder.

    9. Handling failed attempts.
       - The recorder excludes failed Render attempts from the macro action array.
       - Failed attempts may appear only in the macro header debug comments.
       - The reader should ignore debug comments and execute only the returned macro array.
       - If the reader itself fails to verify a step during replay, it must stop instead of
         trying to "catch up" or skip ahead.

    10. Reader output/reporting recommendations.
       - Print current stepIndex, action, placementOrder, unitName, and verification result.
       - For Render success, print the new runtimeGuid but do not save it permanently.
       - For Upgrade success, print the confirmed upgradeLevel.
       - For failure, print the exact expected condition and what was observed.

    11. Common bugs to avoid.
       - Do not use GUID from old files; old GUID is invalid in the next match.
       - Do not identify same-name units by unitName alone; use placementOrder first.
       - Do not assume slotIndex is readable from Workspace; it is mainly an intent value.
       - Do not rely on PlayerGui loading before placing/confirming units.
       - Do not treat missing UpgradeText as failed unless a timeout expires after an
         attempted Upgrade action.
       - Do not allow duplicate Render confirmations for the same unit. Reserve/lock a
         candidate GUID while verifying it.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local VERSION = "MACRO-RECORDER V1.4 - SINGLETON-HOOK"
local SAVE_PATH = "C:/Users/Siwakan Talasak/AppData/Local/Potassium/workspace/"
local SAVE_LUA_FILE = false
local DEFAULT_MAP_NAME = "UNKNOWN_MAP"

local VERIFY_TIMEOUT = 8
local POSITION_TOLERANCE = 3

local recording = false
local steps = {}
local failedSteps = {}
local pendingStep = nil
local recorderToken = {}
local observerConnection = nil
local unitEventHooked = false
local lastCompactJson = nil
local recordingMetadata = nil

local runtimeUnitsByGuid = {}
local runtimeGuidsByPlacementOrder = {}
local seenGuids = {}
local confirmingGuids = {}
local placementCounter = 0

local upgradeUnitConnections = {}
local upgradeLabelConnections = {}
local lastUpgradeByGuid = {}

local function log(message)
    print(string.format("[%s] %s", VERSION, tostring(message)))
end

local function isGuidLike(text)
    return string.match(
        string.lower(text or ""),
        "^[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+$"
    ) ~= nil
end

local function trimLower(text)
    text = tostring(text or "")
    text = string.gsub(text, "^%s*(.-)%s*$", "%1")
    return string.lower(text)
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

local function positionDistance(a, b)
    if typeof(a) ~= "Vector3" or typeof(b) ~= "Vector3" then
        return nil
    end
    return (a - b).Magnitude
end

local function posToString(value)
    if typeof(value) == "Vector3" then
        return string.format("Vector3.new(%.6f, %.6f, %.6f)", value.X, value.Y, value.Z)
    end
    return tostring(value)
end

local function luaString(value)
    local text = tostring(value or "")
    text = string.gsub(text, "\\", "\\\\")
    text = string.gsub(text, '"', '\\"')
    text = string.gsub(text, "\n", "\\n")
    text = string.gsub(text, "\r", "\\r")
    return '"' .. text .. '"'
end

local function luaValue(value)
    if value == nil then
        return "nil"
    end
    if type(value) == "number" or type(value) == "boolean" then
        return tostring(value)
    end
    if typeof(value) == "Vector3" then
        return posToString(value)
    end
    return luaString(value)
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

local function parseUpgradeLevel(text)
    return tonumber(string.match(tostring(text or ""), "^%[(%d+)%]%s*Upgrade!$"))
end

local function disconnectUpgradeLabel(label)
    local connection = upgradeLabelConnections[label]
    if connection then
        connection:Disconnect()
        upgradeLabelConnections[label] = nil
    end
end

local function appendStep(step)
    table.insert(steps, step)
    return #steps
end

local function appendFailedStep(step)
    table.insert(failedSteps, step)
    return #failedSteps
end

local function emitUpgradeStep(guid, label)
    if not recording then
        return
    end
    if not label or not label:IsA("TextLabel") then
        return
    end

    local text = label.Text or ""
    local upgradeLevel = parseUpgradeLevel(text)
    if not upgradeLevel then
        return
    end

    local eventKey = tostring(upgradeLevel) .. "|" .. text
    if lastUpgradeByGuid[guid] == eventKey then
        return
    end
    lastUpgradeByGuid[guid] = eventKey

    local runtimeUnit = runtimeUnitsByGuid[guid]
    if not runtimeUnit then
        log(string.format("upgrade success seen but GUID is not mapped yet | guid=%s | level=%d", guid, upgradeLevel))
        return
    end

    runtimeUnit.upgradeLevel = upgradeLevel

    local stepNumber = appendStep({
        action = "Upgrade",
        placementOrder = runtimeUnit.placementOrder,
        unitName = runtimeUnit.unitName,
        position = runtimeUnit.position,
        slotIndex = runtimeUnit.slotIndex,
        upgradeLevel = upgradeLevel,
        verified = true,
    })

    log(string.format(
        "[STEP %02d] UPGRADE placementOrder=%d unit=%s level=%d confirmed",
        stepNumber,
        runtimeUnit.placementOrder,
        runtimeUnit.unitName,
        upgradeLevel
    ))
end

local function watchUpgradeLabel(guid, label)
    if not label or not label:IsA("TextLabel") then
        return
    end

    emitUpgradeStep(guid, label)

    disconnectUpgradeLabel(label)
    upgradeLabelConnections[label] = label:GetPropertyChangedSignal("Text"):Connect(function()
        emitUpgradeStep(guid, label)
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

    upgradeUnitConnections[guid] = upgradeUnitConnections[guid] or {}
    table.insert(upgradeUnitConnections[guid], childAdded)
end

local function watchUnitUpgradeEvents(unit)
    if not recording then
        return
    end
    if not unit:IsA("Model") or not isGuidLike(unit.Name) then
        return
    end

    local guid = unit.Name
    if upgradeUnitConnections[guid] then
        return
    end

    upgradeUnitConnections[guid] = {}

    local existingUpgradeText = unit:FindFirstChild("UpgradeText")
    if existingUpgradeText then
        watchUpgradeText(guid, existingUpgradeText)
    end

    local descendantAdded = unit.DescendantAdded:Connect(function(descendant)
        if descendant.Name == "UpgradeText" then
            watchUpgradeText(guid, descendant)
        elseif descendant.Name == "Label" and descendant.Parent and descendant.Parent.Name == "UpgradeText" then
            watchUpgradeLabel(guid, descendant)
        end
    end)

    local descendantRemoving = unit.DescendantRemoving:Connect(function(descendant)
        if descendant.Name == "Label" and descendant.Parent and descendant.Parent.Name == "UpgradeText" then
            disconnectUpgradeLabel(descendant)
        end
    end)

    table.insert(upgradeUnitConnections[guid], descendantAdded)
    table.insert(upgradeUnitConnections[guid], descendantRemoving)
end

local function disconnectUpgradeObservers()
    for guid, connections in pairs(upgradeUnitConnections) do
        for _, connection in ipairs(connections) do
            connection:Disconnect()
        end
        upgradeUnitConnections[guid] = nil
    end

    for label, connection in pairs(upgradeLabelConnections) do
        connection:Disconnect()
        upgradeLabelConnections[label] = nil
    end
end

local function verifyPlacementByWorkspace(unit, pending)
    local basePosition = normalizePos(unit:GetAttribute("BasePosition"))
    local pendingPosition = normalizePos(pending.position)
    local distance = positionDistance(basePosition, pendingPosition)

    if distance and distance > POSITION_TOLERANCE then
        return false, string.format("position mismatch distance=%.3f", distance)
    end

    return true, "workspace position matched"
end

local function resolvePlacedUnitName(guid, pending)
    local uiName = getUnitNameFromUpgradeInterface(guid)
    if uiName and uiName ~= "" then
        return uiName, "UpgradeInterfaces"
    end

    return pending.unitName, "pending UnitEvent payload"
end

local function confirmPendingPlacement(unit)
    if not recording or not pendingStep then
        return
    end
    if not unit:IsA("Model") or not isGuidLike(unit.Name) then
        return
    end

    local guid = unit.Name
    if seenGuids[guid] or confirmingGuids[guid] then
        return
    end

    local pending = pendingStep
    confirmingGuids[guid] = pending

    task.spawn(function()
        task.wait(0.75)

        if pendingStep ~= pending then
            confirmingGuids[guid] = nil
            return
        end

        if not unit.Parent then
            confirmingGuids[guid] = nil
            log("unit disappeared before placement confirmation | guid=" .. guid)
            return
        end

        local ok, reason = verifyPlacementByWorkspace(unit, pending)
        if not ok then
            confirmingGuids[guid] = nil
            log(string.format("placement candidate rejected | guid=%s | %s", guid, reason))
            return
        end

        local resolvedName, nameSource = resolvePlacedUnitName(guid, pending)
        if trimLower(resolvedName) ~= trimLower(pending.unitName) then
            confirmingGuids[guid] = nil
            log(string.format(
                "placement name mismatch | sent=%s | resolved=%s | source=%s | guid=%s",
                tostring(pending.unitName),
                tostring(resolvedName),
                tostring(nameSource),
                guid
            ))
            return
        end

        seenGuids[guid] = true
        confirmingGuids[guid] = nil
        placementCounter += 1

        local runtimeUnit = {
            placementOrder = placementCounter,
            runtimeGuid = guid,
            unitName = resolvedName,
            tier = pending.tier,
            position = normalizePos(pending.position),
            rotation = pending.rotation,
            slotIndex = pending.slotIndex,
            upgradeLevel = 0,
        }

        runtimeUnitsByGuid[guid] = runtimeUnit
        runtimeGuidsByPlacementOrder[placementCounter] = guid

        pending.placementOrder = runtimeUnit.placementOrder
        pending.resolvedName = resolvedName
        pending.verified = true
        pending.recorded = true

        local stepNumber = appendStep({
            action = "Render",
            placementOrder = runtimeUnit.placementOrder,
            unitName = runtimeUnit.unitName,
            tier = runtimeUnit.tier,
            position = runtimeUnit.position,
            rotation = runtimeUnit.rotation,
            slotIndex = runtimeUnit.slotIndex,
            upgradeLevel = 0,
            verified = true,
        })

        pendingStep = nil
        watchUnitUpgradeEvents(unit)

        log(string.format(
            "[STEP %02d] RENDER placementOrder=%d unit=%s pos=%s slot=%s verified via %s",
            stepNumber,
            runtimeUnit.placementOrder,
            runtimeUnit.unitName,
            posToString(runtimeUnit.position),
            tostring(runtimeUnit.slotIndex),
            nameSource
        ))
    end)
end

local function installHook()
    local hookState = _G.AVRecorderHookState
    if type(hookState) ~= "table" then
        hookState = { installed = false, callback = nil }
        _G.AVRecorderHookState = hookState
    end

    hookState.callback = function(self, method, args)
        if method == "FireServer" and self.Name == "UnitEvent" and recording then
            local action = tostring(args[1])

            if action == "Render" then
                task.spawn(function()
                    if _G.MacroRecorderToken ~= recorderToken or not recording then
                        return
                    end

                    local rawName = args[2] and args[2][1]
                    local tier = args[2] and args[2][2]
                    local pos = args[2] and normalizePos(args[2][3])
                    local rotation = args[2] and args[2][4]
                    local slotIndex = args[3] and args[3].SlotIndex

                    if not rawName then
                        return
                    end

                    local waitStart = os.clock()
                    while pendingStep ~= nil do
                        if os.clock() - waitStart > VERIFY_TIMEOUT then
                            log("timeout waiting for previous placement confirmation; ignoring new Render")
                            return
                        end
                        task.wait(0.05)
                    end

                    pendingStep = {
                        action = "Render",
                        unitName = rawName,
                        tier = tier,
                        position = pos,
                        rotation = rotation,
                        slotIndex = slotIndex,
                        verified = false,
                        recorded = false,
                    }
                    local currentStep = pendingStep

                    log(string.format(
                        "Render captured | unit=%s | tier=%s | slot=%s | waiting for Workspace.Units confirmation",
                        tostring(rawName),
                        tostring(tier),
                        tostring(slotIndex)
                    ))

                    local deadline = os.clock() + VERIFY_TIMEOUT
                    while pendingStep == currentStep and not currentStep.verified and os.clock() < deadline do
                        task.wait(0.05)
                    end

                    if not currentStep.verified and not currentStep.recorded then
                        currentStep.failed = true
                        currentStep.recorded = true
                        local failedNumber = appendFailedStep({
                            action = "Render",
                            placementOrder = nil,
                            unitName = currentStep.unitName,
                            tier = currentStep.tier,
                            position = currentStep.position,
                            rotation = currentStep.rotation,
                            slotIndex = currentStep.slotIndex,
                            upgradeLevel = 0,
                            verified = false,
                            failed = true,
                        })
                        if pendingStep == currentStep then
                            pendingStep = nil
                        end
                        log(string.format("placement confirmation failed; saved as debug failedStep=%d, not macro action", failedNumber))
                    end
                end)
            end
        end
    end

    if not hookState.installed then
        hookState.installed = true
        local oldNamecall
        oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            local callback = hookState.callback
            if type(callback) == "function" then
                local args = { ... }
                local ok, err = pcall(callback, self, method, args)
                if not ok then
                    warn("[AV-RECORDER-HOOK] callback failed: " .. tostring(err))
                end
            end
            return oldNamecall(self, ...)
        end)
    end

    unitEventHooked = true
    log("UnitEvent.FireServer singleton observer installed")
end

local function connectObserver()
    if observerConnection then
        observerConnection:Disconnect()
        observerConnection = nil
    end

    local units = Workspace:FindFirstChild("Units")
    if not units then
        warn("[" .. VERSION .. "] Workspace.Units not found")
        return false
    end

    for _, child in ipairs(units:GetChildren()) do
        watchUnitUpgradeEvents(child)
    end

    observerConnection = units.ChildAdded:Connect(function(unit)
        watchUnitUpgradeEvents(unit)
        confirmPendingPlacement(unit)
    end)

    log("Workspace.Units observer connected")
    return true
end

local function buildOutputLua()
    local lines = {}
    local function add(line)
        table.insert(lines, line)
    end

    add("--[[")
    add("    MACRO FILE")
    add("    Generated by: " .. VERSION)
    add("    Date: " .. os.date("!%Y-%m-%dT%H:%M:%SZ"))
    add("    Important: GUIDs are intentionally not saved. They are runtime-only.")
    add("    Share format: recorder copies compact JSON to clipboard on stop.")
    add("    JSON short keys: R=Render, U=Upgrade, o=placementOrder, u=unitName, t=tier, p=position, r=rotation, s=slotIndex, l=upgradeLevel.")
    add("    Compact JSON also includes mapName from Workspace.Map:GetAttribute(\"MapName\"); fallback is UNKNOWN_MAP.")
    add("")
    add("    Reader contract:")
    add("    - Execute steps strictly in array order; never reorder by action type.")
    add("    - Do not skip failed/unconfirmed steps. Pause/stop and report the failed step.")
    add("    - Build runtimeByPlacementOrder while replaying Render steps.")
    add("    - Render verification should map placementOrder -> current match Workspace.Units.<GUID>.")
    add("    - Upgrade steps must resolve the current GUID from placementOrder, not from saved data.")
    add("    - Upgrade success is confirmed only by Workspace.Units.<GUID>.UpgradeText.Label.Text = \"[N] Upgrade!\".")
    add("    - UpgradeText is transient; listen for creation/text changes and cache last confirmed N.")
    add("    - Missing UpgradeText during a scan is not failure by itself; timeout after an attempted action is failure.")
    add("    - Stable identity: placementOrder + unitName + position + slotIndex.")
    add("")
    add("    Step-by-step reader build guide:")
    add("    1. Load this file and use the returned macro array exactly as ordered.")
    add("    2. Initialize runtimeByPlacementOrder = {} for the current replay only.")
    add("    3. Before replay, observe Workspace.Units.ChildAdded for new GUID models.")
    add("    4. For each Render step, perform/request placement, then wait for a new GUID model.")
    add("    5. Verify Render by BasePosition near step.position and optional unitName match.")
    add("    6. Map runtimeByPlacementOrder[step.placementOrder] = current match GUID data.")
    add("    7. For each Upgrade step, resolve runtime GUID from placementOrder.")
    add("    8. Attempt/request upgrade, then wait for '[N] Upgrade!' from Workspace.Units.<GUID>.UpgradeText.Label.Text.")
    add("    9. Cache confirmed upgradeLevel because UpgradeText is temporary.")
    add("    10. If any step cannot be verified before timeout, stop/pause; never skip ahead.")
    add("    11. Ignore failed-attempt debug comments; execute only returned macro actions.")
    add("    Verified steps: " .. tostring(#steps))
    add("    Failed/unverified attempts excluded from macro actions: " .. tostring(#failedSteps))
    if #failedSteps > 0 then
        add("")
        add("    Failed attempts debug:")
        for index, failed in ipairs(failedSteps) do
            add(string.format(
                "    - failed[%02d]: action=%s unit=%s slot=%s position=%s reason=unconfirmed placement",
                index,
                tostring(failed.action),
                tostring(failed.unitName),
                tostring(failed.slotIndex),
                posToString(failed.position)
            ))
        end
    end
    add("]]")
    add("")
    add("local macro = {")

    for index, step in ipairs(steps) do
        if step.action == "Upgrade" then
            add(string.format(
                "    -- [STEP %02d] UPGRADE placementOrder=%s unit=%s level=%s",
                index,
                tostring(step.placementOrder),
                tostring(step.unitName),
                tostring(step.upgradeLevel)
            ))
            add(string.format(
                '    { action="Upgrade", placementOrder=%s, unitName=%s, position=%s, slotIndex=%s, upgradeLevel=%s, verified=%s },',
                luaValue(step.placementOrder),
                luaString(step.unitName),
                luaValue(step.position),
                luaValue(step.slotIndex),
                luaValue(step.upgradeLevel),
                tostring(step.verified)
            ))
        else
            add(string.format(
                "    -- [STEP %02d] RENDER placementOrder=%s unit=%s slot=%s%s",
                index,
                tostring(step.placementOrder),
                tostring(step.unitName),
                tostring(step.slotIndex),
                step.verified and "" or " FAILED"
            ))
            add(string.format(
                '    { action="Render", placementOrder=%s, unitName=%s, tier=%s, position=%s, rotation=%s, slotIndex=%s, upgradeLevel=%s, verified=%s },',
                luaValue(step.placementOrder),
                luaString(step.unitName),
                luaString(step.tier),
                luaValue(step.position),
                luaValue(step.rotation),
                luaValue(step.slotIndex),
                luaValue(step.upgradeLevel or 0),
                tostring(step.verified)
            ))
        end
    end

    add("}")
    add("")
    add("return macro")
    return table.concat(lines, "\n")
end

local function vectorToCompact(value)
    value = normalizePos(value)
    if typeof(value) == "Vector3" then
        return {
            math.floor(value.X * 1000 + 0.5) / 1000,
            math.floor(value.Y * 1000 + 0.5) / 1000,
            math.floor(value.Z * 1000 + 0.5) / 1000,
        }
    end
    return value
end

local function readCurrentMapName()
    local map = workspace:FindFirstChild("Map")
    if not map then
        return DEFAULT_MAP_NAME
    end

    local value = map:GetAttribute("MapName")
    if value == nil or tostring(value) == "" then
        return DEFAULT_MAP_NAME
    end

    return tostring(value)
end

local function readBrainRecordingMetadata()
    local startedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")

    if type(_G.AVBrainSnapshot) == "function" then
        local ok, snapshot = pcall(_G.AVBrainSnapshot)
        if ok and type(snapshot) == "table" then
            return {
                mapName = snapshot.mapName or DEFAULT_MAP_NAME,
                mapNamePath = snapshot.mapNamePath or 'Workspace.Map:GetAttribute("MapName")',
                recordingStartedPhase = snapshot.phase or "UNKNOWN",
                recordingStartedAt = startedAt,
                brainVersion = snapshot.version,
                brainSource = "AVBrainSnapshot",
            }
        end

        log("Brain snapshot failed at recording start; using fallback map metadata")
    else
        log("Brain missing at recording start; using fallback map metadata")
    end

    return {
        mapName = readCurrentMapName(),
        mapNamePath = 'Workspace.Map:GetAttribute("MapName")',
        recordingStartedPhase = "UNKNOWN",
        recordingStartedAt = startedAt,
        brainVersion = nil,
        brainSource = "fallback",
    }
end

local function buildCompactPayload()
    local compactSteps = {}

    for _, step in ipairs(steps) do
        if step.action == "Render" then
            table.insert(compactSteps, {
                a = "R",
                o = step.placementOrder,
                u = step.unitName,
                t = step.tier,
                p = vectorToCompact(step.position),
                r = step.rotation or 0,
                s = step.slotIndex,
            })
        elseif step.action == "Upgrade" then
            table.insert(compactSteps, {
                a = "U",
                o = step.placementOrder,
                l = step.upgradeLevel,
            })
        end
    end

    return {
        format = "anime-vanguards-macro",
        version = 1,
        recorder = VERSION,
        generatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        mapName = (recordingMetadata and recordingMetadata.mapName) or readCurrentMapName(),
        mapNamePath = (recordingMetadata and recordingMetadata.mapNamePath) or 'Workspace.Map:GetAttribute("MapName")',
        recordingStartedPhase = recordingMetadata and recordingMetadata.recordingStartedPhase or "UNKNOWN",
        recordingStartedAt = recordingMetadata and recordingMetadata.recordingStartedAt or nil,
        brainVersion = recordingMetadata and recordingMetadata.brainVersion or nil,
        brainSource = recordingMetadata and recordingMetadata.brainSource or "fallback",
        identity = "placementOrder+unitName+position+slotIndex",
        steps = compactSteps,
    }
end

local function buildCompactJson()
    return HttpService:JSONEncode(buildCompactPayload())
end

local function copyTextToClipboard(text)
    if typeof(setclipboard) == "function" then
        local ok, err = pcall(setclipboard, text)
        if ok then
            log("compact JSON copied to clipboard")
            return true
        end
        log("setclipboard failed: " .. tostring(err))
    end

    log("setclipboard unavailable; printing compact JSON")
    print(text)
    return false
end

local function macroStart()
    if recording then
        log("already recording")
        return
    end

    steps = {}
    failedSteps = {}
    pendingStep = nil
    seenGuids = {}
    confirmingGuids = {}
    runtimeUnitsByGuid = {}
    runtimeGuidsByPlacementOrder = {}
    lastUpgradeByGuid = {}
    placementCounter = 0
    recordingMetadata = readBrainRecordingMetadata()
    recording = true

    disconnectUpgradeObservers()
    installHook()
    connectObserver()

    log("recording started | mapName=" .. tostring(recordingMetadata.mapName) .. " | phase=" .. tostring(recordingMetadata.recordingStartedPhase) .. " | brainSource=" .. tostring(recordingMetadata.brainSource))
    log("stop: _G.MacroStop()")
end

local function macroStop()
    if not recording then
        log("not recording")
        return
    end

    if pendingStep then
        local deadline = os.clock() + VERIFY_TIMEOUT
        while pendingStep ~= nil and os.clock() < deadline do
            task.wait(0.05)
        end

        if pendingStep then
            appendFailedStep({
                action = "Render",
                placementOrder = nil,
                unitName = pendingStep.unitName,
                tier = pendingStep.tier,
                position = pendingStep.position,
                rotation = pendingStep.rotation,
                slotIndex = pendingStep.slotIndex,
                upgradeLevel = 0,
                verified = false,
                failed = true,
            })
            pendingStep = nil
        end
    end

    recording = false
    if type(_G.AVRecorderHookState) == "table" then
        _G.AVRecorderHookState.callback = nil
    end

    if observerConnection then
        observerConnection:Disconnect()
        observerConnection = nil
    end

    disconnectUpgradeObservers()

    log(string.format("recording stopped | steps=%d | placements=%d", #steps, placementCounter))
    if #failedSteps > 0 then
        log(string.format("failed attempts excluded from macro actions | failedSteps=%d", #failedSteps))
    end

    local timestamp = tostring(os.time())
    local compactJson = buildCompactJson()
    lastCompactJson = compactJson
    copyTextToClipboard(compactJson)

    if SAVE_LUA_FILE and typeof(writefile) == "function" then
        local content = buildOutputLua()
        local filename = SAVE_PATH .. "macro_" .. timestamp .. ".lua"

        local ok, err = pcall(writefile, filename, content)
        if ok then
            log("saved: " .. filename)
        else
            log("writefile failed: " .. tostring(err))
            print(content)
        end
    elseif SAVE_LUA_FILE then
        log("writefile unavailable; printing Lua macro backup")
        print(buildOutputLua())
    else
        log("Lua file save disabled; compact JSON is the macro output")
    end
end

local function macroCopyLastJson()
    if lastCompactJson then
        copyTextToClipboard(lastCompactJson)
    else
        log("no compact JSON available yet; stop a recording first")
    end
end

local function macroStatus()
    log(string.format(
        "recording=%s | steps=%d | placements=%d | pending=%s",
        tostring(recording),
        #steps,
        placementCounter,
        pendingStep and tostring(pendingStep.unitName) or "none"
    ))
end

local function macroClear()
    steps = {}
    failedSteps = {}
    pendingStep = nil
    seenGuids = {}
    confirmingGuids = {}
    runtimeUnitsByGuid = {}
    runtimeGuidsByPlacementOrder = {}
    lastUpgradeByGuid = {}
    placementCounter = 0
    disconnectUpgradeObservers()
    if not recording and type(_G.AVRecorderHookState) == "table" then
        _G.AVRecorderHookState.callback = nil
    end
    log("cleared")
end

local function createRecorderUi()
    local guiParent = player:FindFirstChild("PlayerGui")
    if not guiParent then
        log("PlayerGui not ready; recorder UI skipped")
        return
    end

    local oldGui = guiParent:FindFirstChild("MacroRecorderControlGui")
    if oldGui then
        oldGui:Destroy()
    end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "MacroRecorderControlGui"
    screenGui.ResetOnSpawn = false
    screenGui.IgnoreGuiInset = false
    screenGui.Parent = guiParent

    local frame = Instance.new("Frame")
    frame.Name = "Panel"
    frame.AnchorPoint = Vector2.new(0, 0.5)
    frame.Position = UDim2.new(0, 14, 0.5, 0)
    frame.Size = UDim2.new(0, 210, 0, 168)
    frame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
    frame.BackgroundTransparency = 0.12
    frame.BorderSizePixel = 0
    frame.Parent = screenGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(255, 190, 80)
    stroke.Thickness = 1
    stroke.Transparency = 0.25
    stroke.Parent = frame

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.Position = UDim2.new(0, 10, 0, 8)
    title.Size = UDim2.new(1, -20, 0, 24)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.TextColor3 = Color3.fromRGB(255, 222, 150)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "Macro Recorder"
    title.Parent = frame

    local statusLabel = Instance.new("TextLabel")
    statusLabel.Name = "Status"
    statusLabel.Position = UDim2.new(0, 10, 0, 34)
    statusLabel.Size = UDim2.new(1, -20, 0, 28)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Font = Enum.Font.Gotham
    statusLabel.TextSize = 12
    statusLabel.TextColor3 = Color3.fromRGB(220, 220, 230)
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.TextWrapped = true
    statusLabel.Text = "Idle | steps=0 | placements=0"
    statusLabel.Parent = frame

    local function refreshStatus()
        statusLabel.Text = string.format(
            "%s | steps=%d | placements=%d | pending=%s",
            recording and "Recording" or "Idle",
            #steps,
            placementCounter,
            pendingStep and tostring(pendingStep.unitName) or "none"
        )
        statusLabel.TextColor3 = recording and Color3.fromRGB(120, 255, 150) or Color3.fromRGB(220, 220, 230)
    end

    local function makeButton(name, text, x, y, color, callback)
        local button = Instance.new("TextButton")
        button.Name = name
        button.Position = UDim2.new(0, x, 0, y)
        button.Size = UDim2.new(0, 92, 0, 30)
        button.BackgroundColor3 = color
        button.BorderSizePixel = 0
        button.Font = Enum.Font.GothamBold
        button.TextSize = 13
        button.TextColor3 = Color3.fromRGB(255, 255, 255)
        button.Text = text
        button.Parent = frame

        local buttonCorner = Instance.new("UICorner")
        buttonCorner.CornerRadius = UDim.new(0, 7)
        buttonCorner.Parent = button

        button.MouseButton1Click:Connect(function()
            callback()
            task.defer(refreshStatus)
        end)

        return button
    end

    makeButton("Start", "Start", 10, 70, Color3.fromRGB(45, 150, 80), macroStart)
    makeButton("Stop", "Stop", 108, 70, Color3.fromRGB(180, 68, 60), macroStop)
    makeButton("StatusButton", "Status", 10, 108, Color3.fromRGB(70, 105, 180), macroStatus)
    makeButton("Clear", "Clear", 108, 108, Color3.fromRGB(110, 100, 110), macroClear)

    local hint = Instance.new("TextLabel")
    hint.Name = "Hint"
    hint.Position = UDim2.new(0, 10, 0, 142)
    hint.Size = UDim2.new(1, -20, 0, 16)
    hint.BackgroundTransparency = 1
    hint.Font = Enum.Font.Gotham
    hint.TextSize = 10
    hint.TextColor3 = Color3.fromRGB(170, 170, 180)
    hint.TextXAlignment = Enum.TextXAlignment.Left
    hint.Text = "Stop copies compact JSON"
    hint.Parent = frame

    task.spawn(function()
        while screenGui.Parent do
            refreshStatus()
            task.wait(0.5)
        end
    end)

    refreshStatus()
    log("recorder UI created")
end

_G.MacroRecorderToken = recorderToken
_G.MacroStart = macroStart
_G.MacroStop = macroStop
_G.MacroStatus = macroStatus
_G.MacroClear = macroClear
_G.MacroRecorderCreateUi = createRecorderUi
_G.MacroCopyLastJson = macroCopyLastJson
_G.AVMacroStop = function()
    macroStop()
    if type(_G.MacroReaderStop) == "function" then
        pcall(_G.MacroReaderStop)
    end
    if type(_G.AVBrainStop) == "function" then
        pcall(_G.AVBrainStop)
    end
end

log("loaded | auto-record enabled")
log("stop all: _G.AVMacroStop()")
log("status: _G.MacroStatus()")
log("create ui: _G.MacroRecorderCreateUi()")
log("copy last JSON: _G.MacroCopyLastJson()")

task.defer(createRecorderUi)
task.defer(macroStart)
