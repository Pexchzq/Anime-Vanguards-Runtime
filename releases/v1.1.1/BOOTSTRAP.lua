--[[
    ANIME VANGUARDS MACRO SYSTEM BOOTSTRAP
    RELEASE: v1.1.1

    Performance release: cached Brain, match-end retry guard, singleton Recorder hook.
    Stop Brain + Reader + Controller with: _G.AVStop()
]]

local RELEASE = "v1.1.1"
local RUNTIME_RELEASE = "v1.1.0"
local CACHE_BUST = "team-equip-first-v111"
local BASE_URL = "https://raw.githubusercontent.com/Pexchzq/Anime-Vanguards-Runtime/main/releases/" .. RUNTIME_RELEASE .. "/runtime/"

local CRITICAL_FILES = {
    "MACRO-BRAIN.lua",
    "AV-EYES-INVENTORY.lua",
    "MAP-MACRO-CONFIG.lua",
    "AV-CONTROLLER-CONFIG.lua",
    "AV-TEAM-EQUIP-CONTROLLER.lua",
}

local OPTIONAL_FILES = {
    "MACRO-READER.lua",
    "AV-MACRO-CONTROLLER.lua",
}

local function log(message)
    print("[AV-BOOTSTRAP " .. RELEASE .. "] " .. tostring(message))
end

local function loadRemoteFile(fileName)
    local url = BASE_URL .. fileName .. "?cb=" .. CACHE_BUST
    log("loading " .. fileName)

    local ok, source = pcall(function()
        return game:HttpGet(url)
    end)
    assert(ok, "HTTP load failed: " .. fileName .. " | " .. tostring(source))

    local chunk, compileError = loadstring(source, "@" .. fileName)
    assert(chunk, "Compile failed: " .. fileName .. " | " .. tostring(compileError))

    local executed, runtimeError = pcall(chunk)
    assert(executed, "Runtime failed: " .. fileName .. " | " .. tostring(runtimeError))
end

if type(_G.AVStop) == "function" then
    pcall(_G.AVStop)
end

for _, fileName in ipairs(CRITICAL_FILES) do
    loadRemoteFile(fileName)
end

for _, fileName in ipairs(OPTIONAL_FILES) do
    local ok, errorMessage = pcall(loadRemoteFile, fileName)
    if not ok then
        log("optional load failed: " .. fileName .. " | " .. tostring(errorMessage))
    end
end

log("system loaded and auto-started")
log("stop Brain + Reader + Controller: _G.AVStop()")
