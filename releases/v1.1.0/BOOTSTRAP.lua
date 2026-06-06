--[[
    ANIME VANGUARDS MACRO SYSTEM BOOTSTRAP
    RELEASE: v1.1.0

    Performance release: cached Brain, match-end retry guard, singleton Recorder hook.
    Stop Brain + Reader + Controller with: _G.AVStop()
]]

local RELEASE = "v1.1.0"
local BASE_URL = "https://raw.githubusercontent.com/Pexchzq/Anime-Vanguards-Runtime/main/releases/" .. RELEASE .. "/runtime/"

local RUNTIME_FILES = {
    "MACRO-BRAIN.lua",
    "AV-EYES-INVENTORY.lua",
    "MAP-MACRO-CONFIG.lua",
    "AV-CONTROLLER-CONFIG.lua",
    "MACRO-READER.lua",
    "AV-MACRO-CONTROLLER.lua",
    "AV-TEAM-EQUIP-CONTROLLER.lua",
}

local function log(message)
    print("[AV-BOOTSTRAP " .. RELEASE .. "] " .. tostring(message))
end

local function loadRemoteFile(fileName)
    local url = BASE_URL .. fileName
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

for _, fileName in ipairs(RUNTIME_FILES) do
    loadRemoteFile(fileName)
end

log("system loaded and auto-started")
log("stop Brain + Reader + Controller: _G.AVStop()")
