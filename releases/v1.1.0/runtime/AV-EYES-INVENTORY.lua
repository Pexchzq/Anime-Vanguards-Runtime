--[[
    AV EYES INVENTORY
    VERSION: V1.0

    Role:
    - Read owned unit UUIDs and names from the confirmed GlobalInventory cache.
    - Expose a stable snapshot for controllers.
    - Read-only only. This file never fires remotes and never clicks UI.

    Confirmed source:
        Players.LocalPlayer.PlayerGui.Windows.GlobalInventory.Holder.LeftContainer
            .FakeScrollingFrame.Items.CacheContainer.<UUID>

    Confirmed name:
        CacheContainer.<UUID>.Container.Holder.Main.UnitName.Text

    Commands:
        _G.AVEyesInventoryStart()
        _G.AVEyesInventoryStop()
        _G.AVEyesInventorySnapshot()
        _G.AVEyesInventoryStatus()
        _G.AVEyesInventoryPrint()
]]

local Players = game:GetService("Players")

local VERSION = "AV-EYES-INVENTORY V1.0"
local SCAN_INTERVAL_SECONDS = 2
local UUID_PATTERN = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local player = Players.LocalPlayer
while not player do
    Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
    player = Players.LocalPlayer
end

local state = {
    running = false,
    stopRequested = false,
    updatedAt = 0,
    cacheExists = false,
    count = 0,
    units = {},
    reason = "not scanned",
}

local previousAVStop = rawget(_G, "AVStop")

local function log(message)
    print("[" .. VERSION .. "] " .. tostring(message))
end

local function isUuid(value)
    return string.match(string.lower(tostring(value)), UUID_PATTERN) ~= nil
end

local function getPlayerGui()
    return player:FindFirstChildOfClass("PlayerGui")
end

local function findCacheContainer()
    local playerGui = getPlayerGui()
    local windows = playerGui and playerGui:FindFirstChild("Windows")
    local inventory = windows and windows:FindFirstChild("GlobalInventory")
    local holder = inventory and inventory:FindFirstChild("Holder")
    local leftContainer = holder and holder:FindFirstChild("LeftContainer")
    local fakeScrollingFrame = leftContainer and leftContainer:FindFirstChild("FakeScrollingFrame")
    local items = fakeScrollingFrame and fakeScrollingFrame:FindFirstChild("Items")
    return items and items:FindFirstChild("CacheContainer") or nil
end

local function readTextObject(root, path)
    local current = root
    for part in string.gmatch(path, "[^%.]+") do
        current = current and current:FindFirstChild(part)
    end

    if current and (current:IsA("TextLabel") or current:IsA("TextButton") or current:IsA("TextBox")) then
        return current.Text
    end
    return nil
end

local function readUnitCard(card)
    local uuid = tostring(card and card.Name or "")
    if not isUuid(uuid) then
        return nil
    end

    local unitName = readTextObject(card, "Container.Holder.Main.UnitName") or "<unknown>"
    local levelText = readTextObject(card, "Container.Holder.Main.Level") or readTextObject(card, "Container.Holder.Main.UnitLevel")

    return {
        uuid = uuid,
        name = unitName,
        levelText = levelText,
        path = card:GetFullName(),
    }
end

local function refresh()
    local container = findCacheContainer()
    local units = {}

    if not container then
        state.cacheExists = false
        state.units = {}
        state.count = 0
        state.reason = "GlobalInventory CacheContainer missing"
        state.updatedAt = os.clock()
        return false
    end

    local seen = {}
    for _, card in ipairs(container:GetChildren()) do
        local unit = readUnitCard(card)
        if unit and not seen[unit.uuid] then
            seen[unit.uuid] = true
            units[#units + 1] = unit
        end
    end

    table.sort(units, function(a, b)
        if a.name == b.name then
            return a.uuid < b.uuid
        end
        return a.name < b.name
    end)

    state.cacheExists = true
    state.units = units
    state.count = #units
    state.reason = #units > 0 and "ok" or "cache exists but no uuid cards"
    state.updatedAt = os.clock()
    return true
end

local function copyUnits(units)
    local copy = {}
    for index, unit in ipairs(units or {}) do
        copy[index] = {
            uuid = unit.uuid,
            name = unit.name,
            levelText = unit.levelText,
            path = unit.path,
        }
    end
    return copy
end

local function snapshot()
    if state.updatedAt == 0 or (os.clock() - state.updatedAt) > (SCAN_INTERVAL_SECONDS * 2) then
        refresh()
    end

    return {
        version = VERSION,
        running = state.running,
        source = "GlobalInventory.CacheContainer",
        cacheExists = state.cacheExists,
        count = state.count,
        units = copyUnits(state.units),
        updatedAt = state.updatedAt,
        snapshotAgeSeconds = state.updatedAt > 0 and (os.clock() - state.updatedAt) or math.huge,
        reason = state.reason,
    }
end

local function resolveByName(unitName, usedUuids)
    local wantedName = tostring(unitName)
    local used = usedUuids or {}
    local current = snapshot()

    for _, unit in ipairs(current.units) do
        if unit.name == wantedName and not used[unit.uuid] then
            return unit
        end
    end

    return nil
end

local function printInventory()
    local current = snapshot()
    log("inventory | cacheExists=" .. tostring(current.cacheExists) .. " | count=" .. tostring(current.count) .. " | reason=" .. tostring(current.reason))
    for index, unit in ipairs(current.units) do
        log(string.format("  [%03d] name=%s | uuid=%s | level=%s", index, tostring(unit.name), tostring(unit.uuid), tostring(unit.levelText or "<none>")))
    end
end

local function status()
    local current = snapshot()
    log(
        "running=" .. tostring(current.running)
            .. " | cacheExists=" .. tostring(current.cacheExists)
            .. " | units=" .. tostring(current.count)
            .. " | age=" .. string.format("%.2f", current.snapshotAgeSeconds)
            .. " | reason=" .. tostring(current.reason)
    )
end

local function start()
    if state.running then
        return true
    end

    state.running = true
    state.stopRequested = false
    refresh()
    log("started | scanInterval=" .. tostring(SCAN_INTERVAL_SECONDS) .. "s")

    task.spawn(function()
        while state.running and not state.stopRequested do
            refresh()
            task.wait(SCAN_INTERVAL_SECONDS)
        end
    end)

    return true
end

local function stop()
    state.stopRequested = true
    state.running = false
    log("stopped")
end

_G.AVEyesInventoryStart = start
_G.AVEyesInventoryStop = stop
_G.AVEyesInventorySnapshot = snapshot
_G.AVEyesInventoryResolveByName = resolveByName
_G.AVEyesInventoryStatus = status
_G.AVEyesInventoryPrint = printInventory

_G.AVStop = function()
    if type(previousAVStop) == "function" then
        pcall(previousAVStop)
    end
    stop()
end

start()
