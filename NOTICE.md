# Components and licences

Dungeons for Mac runs the Microsoft Store (MSIXVC) copy of Minecraft Dungeons that
you own on an Apple silicon Mac. It contains no game content, keys or licence
bypass: the game is downloaded from Microsoft with your own account, and
Microsoft's licensing service decides whether you may play it.

| Directory | What | Licence |
|---|---|---|
| `app/` | The Dungeons for Mac app (shell + AppleScript) | MIT |
| `engine/patches/highball/` | Highball's Mac patch series for the CrossOver 26.3 Wine tree, from github.com/gauthierpiarrette/highball-engine | LGPL-2.1-or-later |
| `engine/patches/xodus/` | The Xodus project's Wine commits (memfd/file-map loading, GDK fixes, windows.web JSON, xgameruntime), exported from github.com/xodus-gaming/wine | LGPL-2.1-or-later |
| `engine/patches/ferestre/wine/`, `engine/patches/ferestre/xgameruntime/` | Ferestre's runtime patches, from github.com/icex/ferestre | LGPL-2.1-or-later |
| `engine/patches/ferestre/xodus-cli/` | Ferestre's client patches | GPL-3.0-or-later (applied to Xodus, GPL-3.0-only) |
| Built engine | Wine from CodeWeavers' CrossOver sources with the patches above, xgameruntime (github.com/xodus-gaming/xgameruntime) | LGPL-2.1-or-later |
| Built client | Xodus (github.com/xodus-gaming/xodus) | GPL-3.0-only |
| Renderers | DXMT (github.com/3Shain/dxmt) | MIT |

Every patch keeps its original author and commit message. Binaries built here
come with their corresponding source: this repository plus the pinned upstream
trees in `engine/inputs.json`.

Not affiliated with Microsoft, Mojang, Valve, CodeWeavers, Highball, Xodus or Ferestre.
