# Anime Vanguards Macro System v1.1.4

Managed startup release with Goal Complete flow and reader replay re-arm fix.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Pexchzq/Anime-Vanguards-Runtime/main/releases/v1.1.4/BOOTSTRAP.lua"))()
```

What changed:
- Adds `AV-GOAL-COMPLETE-CONTROLLER.lua`.
- Keeps Brain read-only and Reader limited to Render/Upgrade.
- Goal completion can return the player to Lobby through `TeleportEvent`.
- Bootstrap starts GoalComplete, StageRouter, and TeamEquip in controlled order.
- Reader remembers when the previous round already ended and waits for the next start gate directly after replay.

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
