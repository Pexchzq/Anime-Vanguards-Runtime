# Anime Vanguards Runtime

Public, versioned runtime releases only. Development source, debug scripts,
path tests, and archives remain in the private repository.

## Current Release

- [`v1.1.9`](releases/v1.1.9/BOOTSTRAP.lua)
- [`v1.1.8`](releases/v1.1.8/BOOTSTRAP.lua) ignores the `PirateDynasty` block in
  `AV-RUNTIME-CONFIG.lua` and can re-fire pre-match remotes while a Pirate
  Dynasty match is still loading.

Run with one command:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Pexchzq/Anime-Vanguards-Runtime/main/releases/v1.1.9/BOOTSTRAP.lua"))()
```

Release directories are immutable. Publish fixes and changes under a new
version directory.
Versioned public runtime releases for Anime Vanguards macro system
