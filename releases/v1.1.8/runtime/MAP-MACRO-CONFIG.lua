--[=[
    MAP MACRO CONFIG
    VERSION: V1.2

    Portable usage:
    1. Execute this config script first.
    2. It sets _G.AVMacroConfig.
    3. Execute MACRO-READER.lua. Reader auto-selects the first enabled macro whose
       macro.mapName matches Workspace.Map:GetAttribute("MapName").

    Add macros below with one of these helpers:
        AddMacro([[PASTE_COMPACT_JSON_HERE]])
        AddUrl("https://cdn.discordapp.com/attachments/...")
        AddFile("C:/path/to/macro.json")

    You can add multiple macros. Keep each macro JSON raw; no map name is needed
    outside the JSON because the recorder already stores "mapName" in the macro.
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

-- =========================
-- PASTE MACROS BELOW
-- =========================

AddMacro([[{"mapNamePath":"Workspace.Map:GetAttribute(\"MapName\")","steps":[{"a":"R","p":[-151.285,253.488,594.771],"s":1,"r":0,"u":"Delusional Demon (Blood)","t":"370:Evolved","o":1},{"a":"R","p":[-109.364,253.543,593.956],"s":1,"r":0,"u":"Delusional Demon (Blood)","t":"370:Evolved","o":2},{"a":"R","p":[-108.713,253.543,587.655],"s":1,"r":0,"u":"Delusional Demon (Blood)","t":"370:Evolved","o":3},{"a":"U","l":1,"o":3},{"a":"U","l":2,"o":3},{"a":"U","l":3,"o":3},{"a":"U","l":1,"o":2},{"a":"U","l":2,"o":2},{"a":"U","l":3,"o":2},{"a":"U","l":4,"o":2},{"a":"U","l":4,"o":3},{"a":"U","l":5,"o":2},{"a":"U","l":6,"o":2},{"a":"U","l":7,"o":2}],"mapName":"Downtown Tokyo","identity":"placementOrder+unitName+position+slotIndex","brainSource":"AVBrainSnapshot","brainVersion":"AV-MACRO-BRAIN MAIN-SCRIPT V1.6","version":1,"recordingStartedAt":"2026-06-03T08:51:08Z","recordingStartedPhase":"MATCH_READY_OR_EMPTY","format":"anime-vanguards-macro","generatedAt":"2026-06-03T08:57:41Z","recorder":"MACRO-RECORDER V1.3 - BRAIN-METADATA"}]], "Downtown Tokyo")

-- Add more macros like this:
-- AddMacro([[{"version":1,"format":"anime-vanguards-macro","mapName":"Another Map","steps":[]}]], "Another Map")
-- AddUrl("https://cdn.discordapp.com/attachments/.../macro.json", "Discord CDN macro")
-- AddFile("C:/Users/YourName/Desktop/macro.json", "Local backup macro")

-- =========================
-- READER SETTINGS
-- =========================

local config = {
    Version = 1.2,
    DefaultMapName = "UNKNOWN_MAP",

    -- Optional guard. Default false: Reader starts when mapName matches and EndScreen is false.
    RequireEmptyPlacedUnitsOnStart = false,

    -- Reserved for future looping behavior. Current reader does not auto-loop by default.
    RestartFromFirstStepAfterMatchEnd = false,

    MacroSources = MacroSources,

    -- Backward compatibility only. Prefer AddMacro/AddUrl/AddFile above.
    Maps = {},
}

_G.AVMacroConfig = config
print("[Config] macro sources loaded | sources=" .. tostring(#MacroSources))

return config
