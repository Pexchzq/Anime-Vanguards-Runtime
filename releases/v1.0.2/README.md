# Anime Vanguards Macro System v1.0.2

Reader stays armed after a completed match. It waits for EndScreen to appear,
then waits for EndScreen to disappear and the map name to match before restarting
the macro from step 1.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Pexchzq/Anime-Vanguards-Runtime/main/releases/v1.0.2/BOOTSTRAP.lua"))()
```

Stop Brain, Reader, and Controller:

```lua
_G.AVStop()
```
