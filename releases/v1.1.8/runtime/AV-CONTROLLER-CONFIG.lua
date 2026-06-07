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

    OnGoalComplete = {
        -- External systems can set _G.AVGoalComplete = true or call _G.AVSetGoalComplete(reason).
        -- This controller is the only owner of the "return to lobby after goal complete" remote.
        Enabled = true,
        AutoStart = true,
        Action = "Lobby", -- Lobby | Stop
        RequireMatchEnd = false,
        DelayBeforeActionSeconds = 2.0,
        ActionCooldownSeconds = 10.0,
        PollSeconds = 1.0,
        Verbose = false,
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

    TeamEquip = {
        -- Unit equip config lives here so Controller/Eyes/Reader can share one control file.
        -- Exact names must match GlobalInventory UnitName.Text.
        Enabled = true,
        AutoStart = true,
        WantedUnits = {},
        EquipAllIfWantedEmpty = true,
        MaxSlots = 6,
        RetryPerUnit = 2,
        VerifyTimeoutSeconds = 2.5,
        VerifyIntervalSeconds = 0.15,
        BetweenUnitSeconds = 0.25,
        StopWhenSlotsFull = true,
        Verbose = false,
        PrintSlotsOnFinish = false,
    },
}

_G.AVControllerConfig = config
print("[Config] controller loaded | endAction=" .. tostring(config.EndScreenPolicy.DefaultAction) .. " | teamEquip=" .. tostring(config.TeamEquip.Enabled))

return config
