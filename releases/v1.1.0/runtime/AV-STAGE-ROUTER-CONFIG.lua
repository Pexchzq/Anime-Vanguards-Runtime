--[[
    AV STAGE ROUTER CONFIG
    VERSION: V1.0

    Purpose:
    - Main condition table for deciding which stage an account should play.
    - Current supported condition: LocalPlayer Level.
    - Future-safe: add more fields under When without changing macro config.

    Rule behavior:
    - First enabled rule that matches wins.
    - MinLevel is inclusive.
    - MaxLevel is exclusive.
]]

local config = {
    Version = 1,

    Enabled = true,
    AutoStart = false,

    LobbyPlaceId = 16146832113,
    DelayBetweenRemotesSeconds = 3,
    VerifyTimeoutSeconds = 30,
    RetrySeconds = 5,
    Verbose = false,

    Rules = {
        {
            Name = "Story Stage11 before level 30",
            Enabled = true,
            When = {
                MaxLevel = 30,
            },
            Match = {
                Difficulty = "Normal",
                Act = "Act1",
                StageType = "Story",
                Stage = "Stage11",
                FriendsOnly = false,
            },
        },
        {
            Name = "Story Stage12 from level 30",
            Enabled = true,
            When = {
                MinLevel = 30,
            },
            Match = {
                Difficulty = "Normal",
                Act = "Act1",
                StageType = "Story",
                Stage = "Stage12",
                FriendsOnly = false,
            },
        },
    },
}

_G.AVStageRouterConfig = config
print("[AV-STAGE-ROUTER-CONFIG V1.0] loaded | rules=" .. tostring(#config.Rules))

return config
