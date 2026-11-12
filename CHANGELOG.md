# Changelog

Versions are named after the game build they were tested against, followed by
a revision number: `1.10-1900.24-2` is the second revision tested against
Command: Modern Operations v1.10 Build 1900.24.

## 1.10-1900.24-2 (2026-11-12)

- A Proton that isn't an 11-series release now gets a warning, and the script
  carries on. It still stops if no Proton is selected for the game or the
  selected one isn't installed.
- When the game's Proton is Proton-Wineland, the script puts
  `PROTON_SET_GAME_DRIVE=0` in front of the launch options, so the game
  recognises that it was started from Steam.
- Launch options the script set for another Proton are replaced on the next
  run. Launch options of your own are still left alone.
- The README says which of the tested Protons run the game through XWayland
  and which as a native Wayland window.

## 1.10-1900.24-1 (2026-11-12)

- The script no longer downloads GE-Proton or forces it for the game. It
  checks which Proton Steam will run the game with (the game's own setting,
  or else Steam's default) and stops unless it is an 11-series release.
- The Steam settings step now only sets the launch options, so only
  `localconfig.vdf` is changed and backed up.
- protontricks is left to pick the same Proton as Steam.
- Tested from a clean install with GE-Proton11-12, and on fresh prefixes with
  Valve's Proton 11.0, Proton-CachyOS 11.0 and Proton-Wineland 11.0.

## Initial version (2026-10-25)

Not tagged.

- Installs a pinned GE-Proton (GE-Proton11-7) and selects it for the game.
- Builds the Proton prefix: .NET Framework 4.8, `d3dcompiler_47`, font
  smoothing, WebView2 runtime 109 and the Selawik fonts.
- Builds `CommandDPI.exe`, a host that runs the game DPI-unaware so that
  `--scale` can scale the whole UI, and sets the launch options to start it.
