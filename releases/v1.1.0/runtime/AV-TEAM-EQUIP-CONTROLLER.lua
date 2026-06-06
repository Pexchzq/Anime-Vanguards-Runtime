--[[
    AV TEAM EQUIP CONTROLLER
    VERSION: V1.0

    Role:
    - Equip owned units using UUID/name data from AV-EYES-INVENTORY.
    - Unit selection lives in:
        config/AV-CONTROLLER-CONFIG V1.0.lua -> _G.AVControllerConfig.TeamEquip.WantedUnits
    - This controller fires only the confirmed EquipEvent.

    Confirmed remote:
        ReplicatedStorage.Networking.Units.EquipEvent:FireServer("Equip", uuid)

    Confirmed verifier:
        Players.LocalPlayer.PlayerGui.HUD.Main.Units.<Slot>.UnitTemplate

    Commands:
        _G.AVTeamEquipStart()
        _G.AVTeamEquipStop()
        _G.AVTeamEquipStatus()
        _G.AVTeamEquipPrintPlan()

    Compatibility aliases:
        _G.AVEquipAutoStart()
        _G.AVEquipAutoStop()
        _G.AVEquipAutoStatus()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VERSION = "AV-TEAM-EQUIP-CONTROLLER V1.0"
local MAX_SLOTS_DEFAULT = 6

local DEFAULT_CONFIG = {
    Enabled = false,
    AutoStart = false,
    WantedUnits = {},
    EquipAllIfWantedEmpty = false,
    MaxSlots = MAX_SLOTS_DEFAULT,
    RetryPerUnit = 2,
    VerifyTimeoutSeconds = 2.5,
    VerifyIntervalSeconds = 0.15,
    BetweenUnitSeconds = 0.25,
    StopWhenSlotsFull = true,
}

local player = Players.LocalPlayer
while not player do
    Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
    player = Players.LocalPlayer
end

local equipEvent = ReplicatedStorage
    :WaitForChild("Networking")
    :WaitForChild("Units")
    :WaitForChild("EquipEvent")

local state = {
    running = false,
    stopRequested = false,
    planned = 0,
    attempted = 0,
    successful = 0,
    missing = 0,
    lastUnitName = nil,
    lastUuid = nil,
    reason = "idle",
}

local previousAVStop = rawget(_G, "AVStop")

local function log(message)
    print("[" .. VERSION .. "] " .. tostring(message))
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

local function getConfig()
    local controllerConfig = rawget(_G, "AVControllerConfig")
    local teamConfig = type(controllerConfig) == "table" and controllerConfig.TeamEquip or nil
    local config = {}

    for key, value in pairs(DEFAULT_CONFIG) do
        if type(value) == "table" then
            config[key] = cloneArray(value)
        else
            config[key] = value
        end
    end

    if type(teamConfig) == "table" then
        for key, value in pairs(teamConfig) do
            if key == "WantedUnits" then
                config[key] = cloneArray(value)
            else
                config[key] = value
            end
        end
    end

    return config
end

local function getPlayerGui()
    return player:FindFirstChildOfClass("PlayerGui")
end

local function findHudSlotsRoot()
    local playerGui = getPlayerGui()
    local hud = playerGui and playerGui:FindFirstChild("HUD")
    local main = hud and hud:FindFirstChild("Main")
    return main and main:FindFirstChild("Units") or nil
end

local function readSlotName(slot)
    local template = slot and slot:FindFirstChild("UnitTemplate")
    local holder = template and template:FindFirstChild("Holder")
    local main = holder and holder:FindFirstChild("Main")
    local unitName = main and main:FindFirstChild("UnitName")
    if unitName and (unitName:IsA("TextLabel") or unitName:IsA("TextButton") or unitName:IsA("TextBox")) then
        return unitName.Text
    end
    return nil
end

local function readSlots(maxSlots)
    local root = findHudSlotsRoot()
    local slots = {}

    for slotIndex = 1, maxSlots do
        local slot = root and root:FindFirstChild(tostring(slotIndex))
        local occupied = slot and slot:FindFirstChild("UnitTemplate") ~= nil
        slots[slotIndex] = {
            occupied = occupied == true,
            name = occupied and readSlotName(slot) or nil,
        }
    end

    return slots
end

local function countOccupied(slots, maxSlots)
    local count = 0
    for slotIndex = 1, maxSlots do
        if slots[slotIndex] and slots[slotIndex].occupied then
            count += 1
        end
    end
    return count
end

local function printSlots()
    local config = getConfig()
    local slots = readSlots(config.MaxSlots)
    local parts = {}
    for slotIndex = 1, config.MaxSlots do
        local slot = slots[slotIndex]
        parts[#parts + 1] = tostring(slotIndex) .. "=" .. tostring(slot and slot.name or "<empty>")
    end
    log("slots | occupied=" .. tostring(countOccupied(slots, config.MaxSlots)) .. "/" .. tostring(config.MaxSlots) .. " | " .. table.concat(parts, " | "))
end

local function getEyesSnapshot()
    if type(_G.AVEyesInventorySnapshot) ~= "function" then
        return nil, "AV-EYES-INVENTORY missing"
    end

    local ok, result = pcall(_G.AVEyesInventorySnapshot)
    if not ok then
        return nil, "Eyes snapshot error: " .. tostring(result)
    end

    return result, nil
end

local function resolveUnitByName(units, name, used)
    for _, unit in ipairs(units) do
        if unit.name == name and not used[unit.uuid] then
            return unit
        end
    end
    return nil
end

local function buildPlan()
    local config = getConfig()
    local snapshot, eyesError = getEyesSnapshot()
    if not snapshot then
        return nil, eyesError
    end

    if not snapshot.cacheExists then
        return nil, "Eyes cache missing: " .. tostring(snapshot.reason)
    end

    local plan = {}
    local used = {}
    local wanted = config.WantedUnits or {}

    if #wanted > 0 then
        for _, wantedName in ipairs(wanted) do
            local unit = resolveUnitByName(snapshot.units, tostring(wantedName), used)
            if unit then
                used[unit.uuid] = true
                plan[#plan + 1] = unit
            else
                state.missing += 1
                log("[PLAN-MISSING] wanted=" .. tostring(wantedName))
            end
        end
    elseif config.EquipAllIfWantedEmpty then
        for _, unit in ipairs(snapshot.units) do
            if not used[unit.uuid] then
                used[unit.uuid] = true
                plan[#plan + 1] = unit
            end
        end
    else
        return nil, "WantedUnits empty and EquipAllIfWantedEmpty=false"
    end

    if #plan == 0 then
        return nil, "no units resolved from Eyes"
    end

    return plan, nil
end

local function waitForOccupiedIncrease(beforeCount, config)
    local deadline = os.clock() + config.VerifyTimeoutSeconds
    while state.running and not state.stopRequested and os.clock() < deadline do
        task.wait(config.VerifyIntervalSeconds)
        local slots = readSlots(config.MaxSlots)
        local afterCount = countOccupied(slots, config.MaxSlots)
        if afterCount > beforeCount then
            return true, afterCount
        end
    end
    return false, countOccupied(readSlots(config.MaxSlots), config.MaxSlots)
end

local function resetRunCounters()
    state.stopRequested = false
    state.planned = 0
    state.attempted = 0
    state.successful = 0
    state.missing = 0
    state.lastUnitName = nil
    state.lastUuid = nil
end

local function finish(reason)
    state.running = false
    state.reason = reason or state.reason
    log("finished | planned=" .. tostring(state.planned) .. " | attempted=" .. tostring(state.attempted) .. " | successful=" .. tostring(state.successful) .. " | missing=" .. tostring(state.missing) .. " | reason=" .. tostring(state.reason))
    printSlots()
end

local function printPlan()
    local plan, errorMessage = buildPlan()
    if not plan then
        log("plan unavailable | reason=" .. tostring(errorMessage))
        return
    end

    log("plan | units=" .. tostring(#plan))
    for index, unit in ipairs(plan) do
        log(string.format("  [%02d] name=%s | uuid=%s", index, tostring(unit.name), tostring(unit.uuid)))
    end
end

local function start()
    if state.running then
        log("already running")
        return false
    end

    local config = getConfig()
    if not config.Enabled then
        state.reason = "TeamEquip disabled in AVControllerConfig.TeamEquip.Enabled"
        log("not started | reason=" .. state.reason)
        return false
    end

    resetRunCounters()

    local slots = readSlots(config.MaxSlots)
    local occupied = countOccupied(slots, config.MaxSlots)
    if occupied >= config.MaxSlots then
        state.reason = "slots already full"
        log("not started | reason=slots already full")
        printSlots()
        return false
    end

    local plan, planError = buildPlan()
    if not plan then
        state.reason = planError
        log("not started | reason=" .. tostring(planError))
        return false
    end

    state.running = true
    state.reason = "running"
    state.planned = #plan
    log("started | planned=" .. tostring(#plan) .. " | occupied=" .. tostring(occupied) .. "/" .. tostring(config.MaxSlots))

    task.spawn(function()
        for _, unit in ipairs(plan) do
            if state.stopRequested then
                finish("manual stop")
                return
            end

            local beforeSlots = readSlots(config.MaxSlots)
            local beforeCount = countOccupied(beforeSlots, config.MaxSlots)
            if beforeCount >= config.MaxSlots and config.StopWhenSlotsFull then
                finish("slots full")
                return
            end

            local verified = false
            local afterCount = beforeCount

            for retry = 1, config.RetryPerUnit do
                if state.stopRequested then
                    finish("manual stop")
                    return
                end

                state.attempted += 1
                state.lastUnitName = unit.name
                state.lastUuid = unit.uuid

                log(string.format("[EQUIP %03d] name=%s | uuid=%s | retry=%d/%d", state.attempted, tostring(unit.name), tostring(unit.uuid), retry, config.RetryPerUnit))
                equipEvent:FireServer("Equip", unit.uuid)

                verified, afterCount = waitForOccupiedIncrease(beforeCount, config)
                if verified then
                    state.successful += 1
                    log("[EQUIP-VERIFIED] name=" .. tostring(unit.name) .. " | uuid=" .. tostring(unit.uuid) .. " | occupiedAfter=" .. tostring(afterCount) .. "/" .. tostring(config.MaxSlots))
                    break
                end
            end

            if not verified then
                log("[EQUIP-NOT-VERIFIED] name=" .. tostring(unit.name) .. " | uuid=" .. tostring(unit.uuid))
            end

            if afterCount >= config.MaxSlots and config.StopWhenSlotsFull then
                finish("slots full")
                return
            end

            task.wait(config.BetweenUnitSeconds)
        end

        finish("plan completed")
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
    log(
        "running=" .. tostring(state.running)
            .. " | enabled=" .. tostring(config.Enabled)
            .. " | autoStart=" .. tostring(config.AutoStart)
            .. " | wanted=" .. tostring(#(config.WantedUnits or {}))
            .. " | planned=" .. tostring(state.planned)
            .. " | attempted=" .. tostring(state.attempted)
            .. " | successful=" .. tostring(state.successful)
            .. " | reason=" .. tostring(state.reason)
    )
    printSlots()
end

_G.AVTeamEquipStart = start
_G.AVTeamEquipStop = stop
_G.AVTeamEquipStatus = status
_G.AVTeamEquipPrintPlan = printPlan

_G.AVEquipAutoStart = start
_G.AVEquipAutoStop = stop
_G.AVEquipAutoStatus = status
_G.AVEquipAutoPrintSlots = printSlots
_G.AVEquipAutoPrintInventory = function()
    if type(_G.AVEyesInventoryPrint) == "function" then
        _G.AVEyesInventoryPrint()
    else
        log("Eyes inventory missing")
    end
end

_G.AVStop = function()
    if type(previousAVStop) == "function" then
        pcall(previousAVStop)
    end
    stop()
end

log("loaded")
log("start: _G.AVTeamEquipStart()")
log("stop: _G.AVTeamEquipStop()")
log("status: _G.AVTeamEquipStatus()")

local initialConfig = getConfig()
if initialConfig.Enabled and initialConfig.AutoStart then
    start()
end
