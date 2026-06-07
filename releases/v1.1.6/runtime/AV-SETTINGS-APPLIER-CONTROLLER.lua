--[=[
    AV SETTINGS APPLIER CONTROLLER V1.0

    หน้าที่:
    - อ่าน config จาก _G.AVControllerConfig.SettingsApplier
    - ขอ settings ปัจจุบันจาก ReplicatedStorage.Networking.Settings.RequestSettings
    - ยิง SettingsEvent เฉพาะ setting boolean ระดับบนที่ format remote ยืนยันแล้ว
    - ทำงานครั้งเดียวตอนเริ่มระบบ แล้วหยุดเอง

    เหตุผลที่แยกไฟล์:
    - Brain/Eyes ต้อง read-only
    - Reader ทำเฉพาะ Render/Upgrade
    - StageRouter ทำเฉพาะเข้าด่าน
    - Settings เป็นงาน setup account จึงเป็น controller แยก
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DEFAULT_CONFIG = {
    Enabled = false,
    AutoStart = false,
    RetrySeconds = 2,
    MaxWaitSeconds = 20,
    VerifyDelaySeconds = 0.75,
    ToggleDelaySeconds = 0.12,
    RequestTimeoutSeconds = 8,
    ApplyOncePerJob = true,
    Verbose = false,
    Config = {},
}

local state = {
    running = false,
    done = false,
    stopRequested = false,
    lastReason = "idle",
    changed = 0,
    skipped = 0,
    unsupported = 0,
    missing = 0,
    failed = 0,
}

local previousAVStop = rawget(_G, "AVStop")

local function log(message)
    print("[Settings] " .. tostring(message))
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
    local controllerConfig = rawget(_G, "AVControllerConfig")
    local source = type(controllerConfig) == "table" and controllerConfig.SettingsApplier or nil
    local config = cloneMap(DEFAULT_CONFIG)

    if type(source) == "table" then
        for key, value in pairs(source) do
            config[key] = value
        end
    end

    config.RetrySeconds = tonumber(config.RetrySeconds) or DEFAULT_CONFIG.RetrySeconds
    config.MaxWaitSeconds = tonumber(config.MaxWaitSeconds) or DEFAULT_CONFIG.MaxWaitSeconds
    config.VerifyDelaySeconds = tonumber(config.VerifyDelaySeconds) or DEFAULT_CONFIG.VerifyDelaySeconds
    config.ToggleDelaySeconds = tonumber(config.ToggleDelaySeconds) or DEFAULT_CONFIG.ToggleDelaySeconds
    config.RequestTimeoutSeconds = tonumber(config.RequestTimeoutSeconds) or DEFAULT_CONFIG.RequestTimeoutSeconds
    if type(config.Config) ~= "table" then
        config.Config = {}
    end

    return config
end

local function getSettingsRemotes()
    local networking = ReplicatedStorage:FindFirstChild("Networking")
    local settingsFolder = networking and networking:FindFirstChild("Settings")
    local requestSettings = settingsFolder and settingsFolder:FindFirstChild("RequestSettings")
    local settingsEvent = settingsFolder and settingsFolder:FindFirstChild("SettingsEvent")

    if not requestSettings or not settingsEvent then
        return nil, nil, "settings remotes missing"
    end

    return requestSettings, settingsEvent, nil
end

local function waitForSettingsResponse(requestSettings, timeoutSeconds)
    local bindable = Instance.new("BindableEvent")
    local connection
    local received = false
    local response = nil

    connection = requestSettings.OnClientEvent:Connect(function(settingsCache)
        if received then
            return
        end
        received = true
        response = settingsCache
        bindable:Fire()
    end)

    requestSettings:FireServer()

    task.delay(timeoutSeconds, function()
        if not received then
            bindable:Fire()
        end
    end)

    bindable.Event:Wait()

    if connection then
        connection:Disconnect()
    end
    bindable:Destroy()

    if not received then
        return nil, "RequestSettings timeout"
    end

    return response, nil
end

local function collectConfigItems(groupName, configValue, currentPath, items)
    for settingName, desiredValue in pairs(configValue) do
        local path = table.clone(currentPath)
        table.insert(path, settingName)

        if type(desiredValue) == "table" then
            collectConfigItems(groupName, desiredValue, path, items)
        else
            table.insert(items, {
                group = groupName,
                setting = settingName,
                path = path,
                desired = desiredValue,
            })
        end
    end
end

local function getSettingByPath(currentSettings, path)
    local value = currentSettings
    for _, key in ipairs(path) do
        if type(value) ~= "table" or value[key] == nil then
            return nil, false
        end
        value = value[key]
    end
    return value, true
end

local function buildPlan(config, currentSettings)
    local plan = {}
    local summary = {
        changed = 0,
        skipped = 0,
        unsupported = 0,
        missing = 0,
    }

    for groupName, groupConfig in pairs(config.Config) do
        if type(groupConfig) == "table" then
            local items = {}
            collectConfigItems(groupName, groupConfig, { groupName }, items)

            for _, item in ipairs(items) do
                local currentValue, found = getSettingByPath(currentSettings, item.path)
                local isTopLevelSetting = #item.path == 2

                item.current = currentValue
                item.found = found

                if not found then
                    item.status = "missing"
                    summary.missing += 1
                elseif type(item.desired) ~= "boolean" or type(currentValue) ~= "boolean" then
                    item.status = "unsupported"
                    item.reason = "only boolean settings are confirmed"
                    summary.unsupported += 1
                elseif not isTopLevelSetting then
                    item.status = "unsupported"
                    item.reason = "nested boolean remote format not confirmed"
                    summary.unsupported += 1
                elseif currentValue == item.desired then
                    item.status = "skipped"
                    summary.skipped += 1
                else
                    item.status = "change"
                    summary.changed += 1
                end

                table.insert(plan, item)
            end
        end
    end

    return plan, summary
end

local function applyPlan(plan, settingsEvent, config)
    for _, item in ipairs(plan) do
        if state.stopRequested then
            return
        end

        if item.status == "change" then
            if config.Verbose then
                log("toggle " .. tostring(item.group) .. "." .. tostring(item.setting)
                    .. " | " .. tostring(item.current) .. " -> " .. tostring(item.desired))
            end
            settingsEvent:FireServer("Toggle", item.setting)
            task.wait(config.ToggleDelaySeconds)
        end
    end
end

local function verifyPlan(plan, verifiedSettings)
    local failed = 0
    for _, item in ipairs(plan) do
        if item.status == "change" then
            local verifiedValue, found = getSettingByPath(verifiedSettings, item.path)
            if not found or verifiedValue ~= item.desired then
                failed += 1
            end
        end
    end
    return failed
end

local function resetSummary()
    state.changed = 0
    state.skipped = 0
    state.unsupported = 0
    state.missing = 0
    state.failed = 0
end

local function loop()
    local config = getConfig()
    local deadline = os.clock() + config.MaxWaitSeconds

    while state.running and not state.stopRequested do
        local requestSettings, settingsEvent, remoteErr = getSettingsRemotes()
        if not requestSettings or not settingsEvent then
            state.lastReason = remoteErr
            if os.clock() >= deadline then
                break
            end
            task.wait(config.RetrySeconds)
            continue
        end

        local currentSettings, err = waitForSettingsResponse(requestSettings, config.RequestTimeoutSeconds)
        if not currentSettings then
            state.lastReason = err
            if os.clock() >= deadline then
                break
            end
            task.wait(config.RetrySeconds)
            continue
        end

        local plan, summary = buildPlan(config, currentSettings)
        applyPlan(plan, settingsEvent, config)
        task.wait(config.VerifyDelaySeconds)

        local verifiedSettings = nil
        verifiedSettings = select(1, waitForSettingsResponse(requestSettings, config.RequestTimeoutSeconds))
        local failed = verifiedSettings and verifyPlan(plan, verifiedSettings) or summary.changed

        state.changed = summary.changed
        state.skipped = summary.skipped
        state.unsupported = summary.unsupported
        state.missing = summary.missing
        state.failed = failed
        state.lastReason = failed > 0 and "verify failed" or "ok"
        state.done = true
        break
    end

    state.running = false
    log("done | changed=" .. tostring(state.changed)
        .. " | skipped=" .. tostring(state.skipped)
        .. " | unsupported=" .. tostring(state.unsupported)
        .. " | missing=" .. tostring(state.missing)
        .. " | failed=" .. tostring(state.failed)
        .. " | reason=" .. tostring(state.lastReason))
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

    if config.ApplyOncePerJob and state.done then
        log("not started | reason=already applied")
        return false
    end

    resetSummary()
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
        .. " | done=" .. tostring(state.done)
        .. " | changed=" .. tostring(state.changed)
        .. " | failed=" .. tostring(state.failed)
        .. " | reason=" .. tostring(state.lastReason))
end

_G.AVSettingsApplyStart = start
_G.AVSettingsApplyStop = stop
_G.AVSettingsApplyStatus = status

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
