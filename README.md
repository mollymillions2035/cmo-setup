# cmo-setup

A setup script for playing the Steam version of
[Command: Modern Operations](https://store.steampowered.com/app/1076160/) on
Linux through Proton.

It is idempotent: every step checks whether it is already done, so you can run
it as often as you like. It never asks Steam to install the game; if the game
isn't installed yet, it sets up what it can and tells you to run it again
afterwards.

## What it does

- Installs GE-Proton11-7 into Steam's `compatibilitytools.d` and selects it for
  the game.
- Creates the game's Proton prefix and installs .NET Framework 4.8,
  `d3dcompiler_47` and subpixel font smoothing through winetricks.
- Installs WebView2 runtime 109, the last one that installs under Wine, so
  briefings and scenario descriptions render. It also marks Steam's own
  WebView2 install script as done, because that newer installer fails.
- Installs [Selawik](https://github.com/microsoft/Selawik), Microsoft's openly
  licensed, metric-compatible stand-in for Segoe UI. Without it, Proton draws
  the game's UI in Times New Roman.
- Optionally scales the UI for high-resolution screens (see below).

Downloads are pinned and checksummed, and cached in `~/.cache/cmo-setup`.

## Requirements

- Steam (native, Flatpak, Snap or the Debian/Ubuntu package)
- `protontricks`, installed natively or with pipx. The Flatpak version isn't
  supported.
- `curl`, `tar`, `awk`, `cmp`, `pgrep`, `sha256sum` and `sha512sum`

## Usage

```sh
./cmo-setup.sh --stop-steam --scale 1.5
```

Then launch the game from Steam as usual.

| Option         | Meaning                                                                 |
| -------------- | ----------------------------------------------------------------------- |
| `--scale N`    | Scale the game's UI by `N` (e.g. `1.5` or `2`). Without it, the DPI is left as it is. |
| `--stop-steam` | Shut Steam down if it's running, so the game's Steam settings can be changed. |
| `--reset`      | Delete the game's Proton prefix and build it again. The game directory isn't touched. |
| `--steam-root` | Path to the Steam directory, if auto-detection doesn't find it.         |

Steam rewrites its settings when it exits, so the script only changes them while
Steam is closed. If Steam is running and you don't pass `--stop-steam`, it
prints what it would have changed, so you can set it in the game's Properties
instead.

## UI scaling

The game declares itself per-monitor DPI aware, but its toolbars have fixed
pixel sizes. With a higher DPI the fonts grow and the toolbars overlap. The
executable is obfuscated and checks itself for tampering, so it can't be
patched.

Instead, the script builds a small host program, `CommandDPI.exe`, with the C#
compiler in the prefix and puts it in the game directory. The host marks its
process as DPI-unaware and then runs the unmodified `Command.exe` inside it.
Wine then scales the whole window to the prefix DPI, which `--scale` sets.
The layout stays intact, though text is slightly soft because it is scaled as a
bitmap.

The game's launch options are set to swap the host in for `Launcher.exe`:

```
bash -c 'exec "${@/Launcher.exe/CommandDPI.exe}"' -- %command%
```

This skips the launcher window. If the game already has launch options of your
own, the script leaves them alone and prints the line to add.

## Undoing it

- Steam settings: the script saves the original files as
  `config/config.vdf.cmo-setup.bak` and
  `userdata/<id>/config/localconfig.vdf.cmo-setup.bak` in your Steam directory.
  You can also clear the launch options and choose another compatibility tool
  in the game's Properties.
- Prefix: delete `steamapps/compatdata/1076160`, and Steam makes a fresh one
  on the next launch.
- Host: delete `CommandDPI.exe` from the game directory.

## License

[CC0 1.0](LICENSE)
