# Anime Vanguards Macro System v1.1.2

Managed startup release. Use this for Auto Execute.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Pexchzq/Anime-Vanguards-Runtime/main/releases/v1.1.2/BOOTSTRAP.lua"))()
```

What changed:
- Controllers no longer auto-start during file load.
- Bootstrap waits for Brain/Eyes before loading controllers.
- Bootstrap starts enabled controllers in order with delays.
- Optional macro Reader/Controller cannot block TeamEquip/StageRouter.

Useful commands:

```lua
_G.AVStop()
_G.AVEyesInventoryStatus()
_G.AVTeamEquipStatus()
_G.AVStageRouterStatus()
```
