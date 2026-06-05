--[[
    AV MACRO CONTROLLER CONFIG
    VERSION: V1.0

    Purpose:
    - Decide what the central Controller should do after EndScreen appears.
    - Controller is the only macro-system file that should fire flow remotes:
        Retry, Next, Lobby.

    Portable usage:
    1. Execute this config script before AV-MACRO-CONTROLLER.lua.
    2. It sets _G.AVControllerConfig.
    3. Edit Rules/DefaultAction to control post-match behavior.
]]

local config = {
    Version = 1,

    EndScreenPolicy = {
        DefaultAction = "Retry", -- Retry | Next | Lobby | Stop
        RequireEndScreen = true,
        StableEndScreenSeconds = 1.5,
        DelayBeforeActionSeconds = 2.0,
        ActionCooldownSeconds = 4.0,
    },

    Rules = {
        {
            Name = "Defeat retry same map",
            Enabled = true,
            When = {
                OutcomeIn = { "DEFEAT", "FAILED" },
            },
            Action = "Retry",
        },
        {
            Name = "Victory next stage",
            Enabled = false,
            When = {
                OutcomeIn = { "VICTORY", "COMPLETE", "CLEARED" },
            },
            Action = "Next",
        },
    },
}

_G.AVControllerConfig = config
print("[AV-CONTROLLER-CONFIG V1.0] loaded | defaultAction=" .. tostring(config.EndScreenPolicy.DefaultAction))

return config
