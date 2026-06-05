# Anime Vanguards Macro System v1.0.0

This release contains only production runtime files. Debug scripts, path tests,
and archived development files are intentionally excluded.

## One-Command Start

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Pexchzq/Anime-Vanguards-Runtime/main/releases/v1.0.0/BOOTSTRAP.lua"))()
```

The bootstrap loads and auto-starts:

1. `MACRO-BRAIN.lua`
2. `MAP-MACRO-CONFIG.lua`
3. `AV-CONTROLLER-CONFIG.lua`
4. `MACRO-READER.lua`
5. `AV-MACRO-CONTROLLER.lua`

Stop Brain, Reader, and Controller:

```lua
_G.AVStop()
```

## Optional Recorder

The recorder is stored at `optional/MACRO-RECORDER.lua` and is not loaded by
the bootstrap. It must be loaded separately when recording a new macro.

This public runtime release is version-locked. Future changes must be published
under a new release directory instead of modifying `v1.0.0`.
