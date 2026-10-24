# Dungeons for Mac

Play the **Microsoft Store** copy of Minecraft Dungeons you already own on an
Apple silicon Mac, without Windows.

> Work in progress. Nothing here runs the game yet.

## How it works

The same approach [Ferestre](https://github.com/icex/ferestre) uses on Linux,
ported to macOS:

1. **Client** ([Xodus](https://github.com/xodus-gaming/xodus)): signs in with
   your Microsoft account, asks Microsoft's licensing service for the game, and
   downloads it. If your account doesn't own the game, Microsoft refuses and
   nothing here gets around that. On macOS the decrypted game lives on a
   temporary RAM disk, never on your drive.
2. **Engine**: Wine 11 from CodeWeavers' CrossOver 26.3 sources with
   [Highball](https://github.com/gauthierpiarrette/highball)'s Mac patches, the
   Xodus and Ferestre patches that let Wine load an Xbox (GDK) game, and
   `xgameruntime.dll`, an open implementation of the Xbox game runtime.
3. **Graphics**: [DXMT](https://github.com/3Shain/dxmt) turns Direct3D 11 into
   Apple Metal.
4. **App** (`app/`): one window to set up, sign in, download and play.

## Status

| Part | State |
|---|---|
| Mac engine build (CrossOver 26.3 + Highball patches) | building |
| Xodus / Ferestre Wine patches on the Mac tree | porting |
| xgameruntime on macOS | to do |
| Xodus client for macOS | to do |
| Minecraft Dungeons (Store, MSIXVC) | untested |

See [NOTICE.md](NOTICE.md) for components and licences.
