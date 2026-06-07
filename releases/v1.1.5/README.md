# Anime Vanguards Macro System v1.1.5

Fixes lobby stage start and cleans runtime console output.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Pexchzq/Anime-Vanguards-Runtime/main/releases/v1.1.5/BOOTSTRAP.lua"))()
```

What changed:
- StageRouter now auto-starts from config.
- Runtime logs no longer print long version names.
- Stage start logs show the useful flow only: selected stage, AddMatch, StartMatch, match detected.
- Keeps the reader replay re-arm fix from v1.1.4.

Stop:

```lua
_G.AVStop()
```
