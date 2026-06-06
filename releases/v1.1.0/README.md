# Anime Vanguards Macro System v1.1.0

Performance and lifecycle update:
- Brain snapshots are cached and expose stale-state metadata.
- Reader stops Render/Upgrade retries when Brain confirms MATCH_END.
- Controller refuses stale Brain state.
- Eyes reads GlobalInventory owned-unit UUID/name snapshots.
- Team Equip Controller equips units from `AV-CONTROLLER-CONFIG.lua -> TeamEquip.WantedUnits`.
- Optional Recorder uses one protected global hook per session.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Pexchzq/Anime-Vanguards-Runtime/main/releases/v1.1.0/BOOTSTRAP.lua"))()
```

Stop Brain, Reader, and Controller:

```lua
_G.AVStop()
```

Team equip commands:

```lua
_G.AVEyesInventoryStatus()
_G.AVEyesInventoryPrint()
_G.AVTeamEquipStart()
_G.AVTeamEquipStatus()
```
