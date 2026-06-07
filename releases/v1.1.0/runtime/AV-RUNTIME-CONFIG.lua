--[=[
    AV RUNTIME CONFIG V1.0

    ไฟล์นี้คือคอนฟิกรวมของระบบทั้งหมด
    แก้ไฟล์นี้ไฟล์เดียวพอ ไม่ต้องไล่แก้หลายไฟล์เหมือนเวอร์ชันเก่า

    สิ่งที่ไฟล์นี้ตั้งค่าให้:
    1. _G.AVMacroConfig        = มาโครที่ Reader ใช้เล่นตามแมพ
    2. _G.AVControllerConfig   = นโยบาย Retry/Next/Lobby และ Team Equip
    3. _G.AVStageRouterConfig  = เงื่อนไขเลือกด่านจากเลเวลหรือเงื่อนไขอื่นในอนาคต

    วิธีใส่มาโคร:
    - วาง JSON ดิบจาก Recorder ใน AddMacro([[ ... ]], "ชื่อโน้ต")
    - ถ้ามีหลายมาโคร ให้เรียก AddMacro หลายครั้ง
    - ไม่ต้องใส่ชื่อแมพแยกนอก JSON เพราะใน JSON มี "mapName" อยู่แล้ว

    หลักการทำงาน:
    - Brain อ่านสถานะเกมอย่างเดียว
    - Eyes อ่าน inventory/unit/account data อย่างเดียว
    - StageRouter ยิง remote เข้าด่านจากกติกาใน StageRouter
    - Reader เล่น macro เมื่อแมพตรงและ EndScreen เป็น false
    - EndController ยิง Retry/Next/Lobby ตอนจบด่าน
    - TeamEquip ใส่ตัวละครจาก inventory ตาม WantedUnits หรือใส่ทั้งหมดถ้าเปิดไว้
]=]

local MacroSources = {}

local function AddMacro(jsonText, notes)
    table.insert(MacroSources, {
        Json = jsonText,
        Enabled = true,
        Notes = notes or "Inline compact JSON",
    })
end

local function AddUrl(url, notes)
    table.insert(MacroSources, {
        Url = url,
        Enabled = true,
        Notes = notes or "Remote JSON URL",
    })
end

local function AddFile(path, notes)
    table.insert(MacroSources, {
        Source = path,
        Enabled = true,
        Notes = notes or "Local JSON file",
    })
end

-- =========================================================
-- 1) MACRO SOURCES
-- วางมาโครดิบตรงนี้ เพิ่มได้หลายอันด้วย AddMacro หลายบรรทัด
-- =========================================================

AddMacro([[{"mapNamePath":"Workspace.Map:GetAttribute(\"MapName\")","steps":[{"a":"R","p":[-151.285,253.488,594.771],"s":1,"r":0,"u":"Delusional Demon (Blood)","t":"370:Evolved","o":1},{"a":"R","p":[-109.364,253.543,593.956],"s":1,"r":0,"u":"Delusional Demon (Blood)","t":"370:Evolved","o":2},{"a":"R","p":[-108.713,253.543,587.655],"s":1,"r":0,"u":"Delusional Demon (Blood)","t":"370:Evolved","o":3},{"a":"U","l":1,"o":3},{"a":"U","l":2,"o":3},{"a":"U","l":3,"o":3},{"a":"U","l":1,"o":2},{"a":"U","l":2,"o":2},{"a":"U","l":3,"o":2},{"a":"U","l":4,"o":2},{"a":"U","l":4,"o":3},{"a":"U","l":5,"o":2},{"a":"U","l":6,"o":2},{"a":"U","l":7,"o":2}],"mapName":"Downtown Tokyo","identity":"placementOrder+unitName+position+slotIndex","brainSource":"AVBrainSnapshot","brainVersion":"AV-MACRO-BRAIN MAIN-SCRIPT V1.6","version":1,"recordingStartedAt":"2026-06-03T08:51:08Z","recordingStartedPhase":"MATCH_READY_OR_EMPTY","format":"anime-vanguards-macro","generatedAt":"2026-06-03T08:57:41Z","recorder":"MACRO-RECORDER V1.3 - BRAIN-METADATA"}]], "Downtown Tokyo")

-- ตัวอย่างเพิ่มมาโคร:
-- AddMacro([[{"version":1,"format":"anime-vanguards-macro","mapName":"Another Map","steps":[]}]], "Another Map")
-- AddUrl("https://cdn.discordapp.com/attachments/.../macro.json", "Discord CDN macro")
-- AddFile("C:/Users/YourName/Desktop/macro.json", "Local macro file")

local MacroConfig = {
    Version = 1.3,
    DefaultMapName = "UNKNOWN_MAP",

    -- false = เริ่มเมื่อ mapName ตรงและ EndScreen=false
    -- true  = ต้องรอ Workspace.Units ว่างด้วย เหมาะกับบางแมพที่ cleanup ค้าง
    RequireEmptyPlacedUnitsOnStart = false,

    RestartFromFirstStepAfterMatchEnd = false,
    MacroSources = MacroSources,
    Maps = {},
}

-- =========================================================
-- 2) CENTRAL CONTROLLER / END SCREEN / TEAM EQUIP
-- =========================================================

local ControllerConfig = {
    Version = 1,

    EndScreenPolicy = {
        DefaultAction = "Retry", -- Retry | Next | Lobby | Stop
        RequireEndScreen = true,
        StableEndScreenSeconds = 1.5,
        DelayBeforeActionSeconds = 2.0,
        ActionCooldownSeconds = 4.0,
    },

    OnGoalComplete = {
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
            When = { OutcomeIn = { "DEFEAT", "FAILED" } },
            Action = "Retry",
        },
        {
            Name = "Victory next stage",
            Enabled = false,
            When = { OutcomeIn = { "VICTORY", "COMPLETE", "CLEARED" } },
            Action = "Next",
        },
    },

    TeamEquip = {
        Enabled = true,
        AutoStart = true,

        -- ถ้าอยากเจาะจงตัว ให้ใส่ชื่อในนี้ เช่น { "Delusional Demon (Blood)", "Sprintwagon" }
        WantedUnits = {},

        -- true = ถ้า WantedUnits ว่าง ให้ใส่ทุกตัวที่ Eyes เจอจนเต็มสล็อต
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

-- =========================================================
-- 3) STAGE ROUTER
-- เลือกด่านจากเลเวล ปรับเพิ่มเงื่อนไขอื่นใน When ได้ภายหลัง
-- =========================================================

local StageRouterConfig = {
    Version = 1,
    Enabled = true,
    AutoStart = true,

    LobbyPlaceId = 16146832113,
    DelayBetweenRemotesSeconds = 3,
    VerifyTimeoutSeconds = 30,
    RetrySeconds = 5,
    Verbose = false,

    Rules = {
        -- กติกาเลือกด่านข้อที่ 1:
        -- ใช้เมื่อเลเวลผู้เล่น "น้อยกว่า 30"
        -- เพราะ MaxLevel = 30 หมายถึง level < 30 ไม่รวม 30
        {
            Name = "Story Stage11 before level 30",
            Enabled = true,
            When = { MaxLevel = 30 },
            Match = {
                -- ค่าด้านล่างคือ payload ที่จะส่งเข้า LobbyEvent เพื่อสร้าง/เริ่มด่าน
                -- แก้ Difficulty / Act / StageType / Stage ให้ตรงกับด่านที่ต้องการ
                Difficulty = "Normal",
                Act = "Act1",
                StageType = "Story",
                Stage = "Stage12",
                FriendsOnly = false,
            },
        },
        -- กติกาเลือกด่านข้อที่ 2:
        -- ใช้เมื่อเลเวลผู้เล่น "ตั้งแต่ 30 ขึ้นไป"
        -- เพราะ MinLevel = 30 หมายถึง level >= 30
        {
            Name = "Story Stage12 from level 30",
            Enabled = true,
            When = { MinLevel = 30 },
            Match = {
                -- ถ้าอยากเปลี่ยนให้เล่นด่านอื่นหลังเลเวลถึงเป้า ให้แก้ block นี้
                Difficulty = "Normal",
                Act = "Act1",
                StageType = "Story",
                Stage = "Stage1",
                FriendsOnly = false,
            },
        },
    },
}

_G.AVMacroConfig = MacroConfig
_G.AVControllerConfig = ControllerConfig
_G.AVStageRouterConfig = StageRouterConfig

print("[Config] runtime loaded | macros=" .. tostring(#MacroSources)
    .. " | stageRules=" .. tostring(#StageRouterConfig.Rules)
    .. " | teamEquip=" .. tostring(ControllerConfig.TeamEquip.Enabled))

return {
    Macro = MacroConfig,
    Controller = ControllerConfig,
    StageRouter = StageRouterConfig,
}
