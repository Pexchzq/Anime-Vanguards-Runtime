# Anime Vanguards Macro System v1.1.3

Managed startup release with Goal Complete flow.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Pexchzq/Anime-Vanguards-Runtime/main/releases/v1.1.3/BOOTSTRAP.lua"))()
```

What changed:
- Adds `AV-GOAL-COMPLETE-CONTROLLER.lua`.
- Keeps Brain read-only and Reader limited to Render/Upgrade.
- Goal completion can return the player to Lobby through `TeleportEvent`.
- Bootstrap starts GoalComplete, StageRouter, and TeamEquip in controlled order.

Goal complete trigger:

```lua
_G.AVSetGoalComplete("target reached")
-- or
_G.AVGoalComplete = true
```

Useful commands:

```lua
_G.AVStop()
_G.AVGoalControllerStatus()
_G.AVEyesInventoryStatus()
_G.AVTeamEquipStatus()
_G.AVStageRouterStatus()
```
