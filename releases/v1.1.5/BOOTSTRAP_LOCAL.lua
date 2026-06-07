-- Local bootstrap for Potassium workspace testing.
-- Loads the runtime files already copied into AppData/Local/Potassium/workspace.

local WORKSPACE = "C:/Users/Siwakan Talasak/AppData/Local/Potassium/workspace/"

local STARTUP = {
    AfterBrainSeconds = 1.0,
    AfterEyesSeconds = 1.0,
    WaitForEyesSeconds = 12.0,
    BeforeControllersSeconds = 1.5,
    BetweenControllerStartsSeconds = 2.0,
}

local PRELOAD_FILES = {
    "MACRO-BRAIN.lua",
    "AV-EYES-INVENTORY.lua",
}

local CONFIG_FILES = {
    "MAP-MACRO-CONFIG.lua",
    "AV-CONTROLLER-CONFIG.lua",
    "AV-STAGE-ROUTER-CONFIG.lua",
}

local CONTROLLER_FILES = {
    "AV-GOAL-COMPLETE-CONTROLLER.lua",
    "AV-STAGE-ROUTER-CONTROLLER.lua",
    "AV-TEAM-EQUIP-CONTROLLER.lua",
}

local OPTIONAL_FILES = {
    "MACRO-READER.lua",
    "AV-MACRO-CONTROLLER.lua",
}

local function log(message)
    print("[Boot] " .. tostring(message))
end

local function loadLocalFile(fileName)
    local path = WORKSPACE .. fileName
    log("loading " .. fileName)

    local chunk, compileError = loadfile(path)
    assert(chunk, "Compile failed: " .. fileName .. " | " .. tostring(compileError))

    local executed, runtimeError = pcall(chunk)
    assert(executed, "Runtime failed: " .. fileName .. " | " .. tostring(runtimeError))
end

local function waitForEyes()
    local deadline = os.clock() + STARTUP.WaitForEyesSeconds
    while os.clock() < deadline do
        if type(_G.AVEyesInventorySnapshot) == "function" then
            local ok, snapshot = pcall(_G.AVEyesInventorySnapshot)
            if ok and snapshot and snapshot.cacheExists then
                log("Eyes ready | units=" .. tostring(snapshot.count))
                return true
            end
        end
        task.wait(0.5)
    end
    log("Eyes wait timeout; controllers will still load")
    return false
end

local function optionalLoad(fileName)
    local ok, errorMessage = pcall(loadLocalFile, fileName)
    if not ok then
        log("optional load failed: " .. fileName .. " | " .. tostring(errorMessage))
    end
end

local function suppressControllerAutoStart()
    local controllerConfig = type(_G.AVControllerConfig) == "table" and _G.AVControllerConfig or {}
    local goalConfig = type(controllerConfig.OnGoalComplete) == "table" and controllerConfig.OnGoalComplete or nil
    local teamConfig = type(controllerConfig.TeamEquip) == "table" and controllerConfig.TeamEquip or nil
    local stageConfig = type(_G.AVStageRouterConfig) == "table" and _G.AVStageRouterConfig or nil

    local original = {
        GoalAutoStart = goalConfig and goalConfig.AutoStart,
        TeamEquipAutoStart = teamConfig and teamConfig.AutoStart,
        StageRouterAutoStart = stageConfig and stageConfig.AutoStart,
    }

    if goalConfig then
        goalConfig.AutoStart = false
    end
    if teamConfig then
        teamConfig.AutoStart = false
    end
    if stageConfig then
        stageConfig.AutoStart = false
    end

    return original
end

local function restoreControllerAutoStart(original)
    local controllerConfig = type(_G.AVControllerConfig) == "table" and _G.AVControllerConfig or {}
    local goalConfig = type(controllerConfig.OnGoalComplete) == "table" and controllerConfig.OnGoalComplete or nil
    local teamConfig = type(controllerConfig.TeamEquip) == "table" and controllerConfig.TeamEquip or nil
    local stageConfig = type(_G.AVStageRouterConfig) == "table" and _G.AVStageRouterConfig or nil

    if goalConfig then
        goalConfig.AutoStart = original.GoalAutoStart
    end
    if teamConfig then
        teamConfig.AutoStart = original.TeamEquipAutoStart
    end
    if stageConfig then
        stageConfig.AutoStart = original.StageRouterAutoStart
    end
end

local function startManagedControllers()
    local controllerConfig = type(_G.AVControllerConfig) == "table" and _G.AVControllerConfig or {}
    local goalConfig = type(controllerConfig.OnGoalComplete) == "table" and controllerConfig.OnGoalComplete or {}
    local teamConfig = type(controllerConfig.TeamEquip) == "table" and controllerConfig.TeamEquip or {}
    local stageConfig = type(_G.AVStageRouterConfig) == "table" and _G.AVStageRouterConfig or {}

    if goalConfig.Enabled and goalConfig.AutoStart and type(_G.AVGoalControllerStart) == "function" then
        log("managed start: GoalComplete")
        pcall(_G.AVGoalControllerStart)
        task.wait(STARTUP.BetweenControllerStartsSeconds)
    end

    if stageConfig.Enabled and stageConfig.AutoStart and type(_G.AVStageRouterStart) == "function" then
        log("managed start: StageRouter")
        pcall(_G.AVStageRouterStart)
        task.wait(STARTUP.BetweenControllerStartsSeconds)
    end

    if teamConfig.Enabled and teamConfig.AutoStart and type(_G.AVTeamEquipStart) == "function" then
        log("managed start: TeamEquip")
        pcall(_G.AVTeamEquipStart)
        task.wait(STARTUP.BetweenControllerStartsSeconds)
    end
end

if type(_G.AVStop) == "function" then
    pcall(_G.AVStop)
end

_G.AVBootstrapManagedStartup = true

loadLocalFile(PRELOAD_FILES[1])
task.wait(STARTUP.AfterBrainSeconds)
loadLocalFile(PRELOAD_FILES[2])
task.wait(STARTUP.AfterEyesSeconds)
waitForEyes()

for _, fileName in ipairs(CONFIG_FILES) do
    loadLocalFile(fileName)
end

task.wait(STARTUP.BeforeControllersSeconds)

local originalAutoStart = suppressControllerAutoStart()
for _, fileName in ipairs(CONTROLLER_FILES) do
    loadLocalFile(fileName)
    task.wait(0.5)
end

restoreControllerAutoStart(originalAutoStart)
startManagedControllers()

for _, fileName in ipairs(OPTIONAL_FILES) do
    optionalLoad(fileName)
end

log("system loaded")
