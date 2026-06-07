--[[
    ANIME VANGUARDS MACRO SYSTEM BOOTSTRAP
    RELEASE: v1.1.8

    Permanent startup sequencer:
    - Prevents controllers from auto-starting during file load.
    - Loads Brain/Eyes first.
    - Waits for Eyes inventory cache readiness.
    - Loads configs/controllers.
    - Starts enabled controllers after controlled delays.
]]

local RELEASE = "v1.1.8"
local RUNTIME_RELEASE = "v1.1.0"
local CACHE_BUST = "unified-config-settings-lazy-remotes-v118"
local BASE_URL = "https://raw.githubusercontent.com/Pexchzq/Anime-Vanguards-Runtime/main/releases/" .. RUNTIME_RELEASE .. "/runtime/"

local STARTUP = {
    AfterBrainSeconds = 1.0,
    AfterEyesSeconds = 1.0,
    WaitForEyesSeconds = 12.0,
    BeforeControllersSeconds = 1.5,
    BetweenControllerStartsSeconds = 2.0,
    HttpTimeoutSeconds = 8.0,
}

local PRELOAD_FILES = {
    "MACRO-BRAIN.lua",
    "AV-EYES-INVENTORY.lua",
}

local CONFIG_FILES = {
    "AV-RUNTIME-CONFIG.lua",
}

local CONTROLLER_FILES = {
    "AV-SETTINGS-APPLIER-CONTROLLER.lua",
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

local function loadRemoteFile(fileName)
    local url = BASE_URL .. fileName .. "?cb=" .. CACHE_BUST
    log("loading " .. fileName)

    local done = false
    local ok = false
    local source = nil

    task.spawn(function()
        ok, source = pcall(function()
            return game:HttpGet(url)
        end)
        done = true
    end)

    local deadline = os.clock() + STARTUP.HttpTimeoutSeconds
    while not done and os.clock() < deadline do
        task.wait(0.1)
    end

    assert(done, "HTTP timeout: " .. fileName .. " | seconds=" .. tostring(STARTUP.HttpTimeoutSeconds))
    assert(ok, "HTTP load failed: " .. fileName .. " | " .. tostring(source))
    assert(type(source) == "string" and #source > 0, "HTTP empty source: " .. fileName)

    local chunk, compileError = loadstring(source, "@" .. fileName)
    assert(chunk, "Compile failed: " .. fileName .. " | " .. tostring(compileError))

    local executed, runtimeError = pcall(chunk)
    assert(executed, "Runtime failed: " .. fileName .. " | " .. tostring(runtimeError))
    log("loaded ok " .. fileName)
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
    local ok, errorMessage = pcall(loadRemoteFile, fileName)
    if not ok then
        log("optional load failed: " .. fileName .. " | " .. tostring(errorMessage))
    end
end

local function startManagedControllers()
    local controllerConfig = type(_G.AVControllerConfig) == "table" and _G.AVControllerConfig or {}
    local settingsConfig = type(controllerConfig.SettingsApplier) == "table" and controllerConfig.SettingsApplier or {}
    local goalConfig = type(controllerConfig.OnGoalComplete) == "table" and controllerConfig.OnGoalComplete or {}
    local teamConfig = type(controllerConfig.TeamEquip) == "table" and controllerConfig.TeamEquip or {}
    local stageConfig = type(_G.AVStageRouterConfig) == "table" and _G.AVStageRouterConfig or {}

    if settingsConfig.Enabled and settingsConfig.AutoStart and type(_G.AVSettingsApplyStart) == "function" then
        log("managed start: SettingsApplier")
        local ok, err = pcall(_G.AVSettingsApplyStart)
        if not ok then
            log("managed start failed: SettingsApplier | " .. tostring(err))
        end
        task.wait(STARTUP.BetweenControllerStartsSeconds)
    else
        log("managed skip: SettingsApplier | enabled=" .. tostring(settingsConfig.Enabled)
            .. " | autoStart=" .. tostring(settingsConfig.AutoStart)
            .. " | fn=" .. tostring(type(_G.AVSettingsApplyStart)))
    end

    if goalConfig.Enabled and goalConfig.AutoStart and type(_G.AVGoalControllerStart) == "function" then
        log("managed start: GoalComplete")
        local ok, err = pcall(_G.AVGoalControllerStart)
        if not ok then
            log("managed start failed: GoalComplete | " .. tostring(err))
        end
        task.wait(STARTUP.BetweenControllerStartsSeconds)
    else
        log("managed skip: GoalComplete | enabled=" .. tostring(goalConfig.Enabled)
            .. " | autoStart=" .. tostring(goalConfig.AutoStart)
            .. " | fn=" .. tostring(type(_G.AVGoalControllerStart)))
    end

    if stageConfig.Enabled and stageConfig.AutoStart and type(_G.AVStageRouterStart) == "function" then
        log("managed start: StageRouter")
        local ok, err = pcall(_G.AVStageRouterStart)
        if not ok then
            log("managed start failed: StageRouter | " .. tostring(err))
        end
        task.wait(STARTUP.BetweenControllerStartsSeconds)
    else
        log("managed skip: StageRouter | enabled=" .. tostring(stageConfig.Enabled)
            .. " | autoStart=" .. tostring(stageConfig.AutoStart)
            .. " | fn=" .. tostring(type(_G.AVStageRouterStart)))
    end

    if teamConfig.Enabled and teamConfig.AutoStart and type(_G.AVTeamEquipStart) == "function" then
        log("managed start: TeamEquip")
        local ok, err = pcall(_G.AVTeamEquipStart)
        if not ok then
            log("managed start failed: TeamEquip | " .. tostring(err))
        end
        task.wait(STARTUP.BetweenControllerStartsSeconds)
    else
        log("managed skip: TeamEquip | enabled=" .. tostring(teamConfig.Enabled)
            .. " | autoStart=" .. tostring(teamConfig.AutoStart)
            .. " | fn=" .. tostring(type(_G.AVTeamEquipStart)))
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

if type(_G.AVStop) == "function" then
    pcall(_G.AVStop)
end

_G.AVBootstrapManagedStartup = true

loadRemoteFile(PRELOAD_FILES[1])
task.wait(STARTUP.AfterBrainSeconds)
loadRemoteFile(PRELOAD_FILES[2])
task.wait(STARTUP.AfterEyesSeconds)
waitForEyes()

for _, fileName in ipairs(CONFIG_FILES) do
    loadRemoteFile(fileName)
end

task.wait(STARTUP.BeforeControllersSeconds)

local originalAutoStart = suppressControllerAutoStart()

for _, fileName in ipairs(CONTROLLER_FILES) do
    optionalLoad(fileName)
    task.wait(0.5)
end

restoreControllerAutoStart(originalAutoStart)
startManagedControllers()

for _, fileName in ipairs(OPTIONAL_FILES) do
    optionalLoad(fileName)
end

log("system loaded")
