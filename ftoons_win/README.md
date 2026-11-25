# ftoons · Windows build - production

Extract the whole ZIP into a writable folder on 64-bit Windows and double-click **ftoons.exe**. Keep `ftoons.pck` and the `native_audio` folder beside it. The executable includes the Godot game runtime. Import and play both work offline.

## First launch

1. Select your DOS game folder, or a ZIP containing it. The supported release has `TOONS.EXE`, `RESOURCE.001` and `ADL.DRV` together.
2. Optionally select the Windows installation, its ZIP, or its original disc image. The Windows files add the alternate graphics and 50 solo puzzles in Home Toons. The full mixed-mode CUE/BIN adds the voiced intros and 24 CD music tracks. A data-only ISO can supply intro speech; the CD music lives on the separate audio tracks.
3. Click **Import and play**. Later launches open directly into the game. To add Windows media later, select an unavailable Windows graphics, intro or CD music option and choose **Open importer**. You can also run `ftoons.exe -- --import-game-files`.

## Playing

The upper-left corner has the display size, graphics, and intro video buttons, with the goal-screen checkbox beneath them. The upper-right corner has the music source and power buttons. Music starts **OFF** (red) and changes to **ON** (green) when enabled. The stage stays centered in either display mode. The lower-left corner shows the graphics status above the music status.

Use the in-game remote control and its **Piggy Bank** load arrow to choose puzzles. **Home Toons**, the fifth category, lists your saved puzzles and, after importing Windows data, the 50 Head-2-head puzzles for solo play.

**Next level** and **Previous level** at the bottom right open adjacent puzzles in list order. Save your arrangement before navigating if you want to return to it later.

**Save game** creates a new `.ftsave` file each time, labeled with the level and time. **Load game** opens the `saves/` folder and restores the selected puzzle in construction mode with the same gadget placement and remaining inventory. Saving during Play captures the arrangement you launched. Finish or cancel a placement before saving. In the Home Toons editor, use the Piggy Bank to save the authored puzzle itself.

## Portable files and custom levels

| Path beside ftoons.exe | Purpose |
| --- | --- |
| `assets/` | Imported DOS campaign, artwork and sound |
| `dlc_win_data/` | Optional Windows graphics, levels, intros and audio |
| `player_data/user_levels/` | Your Home Toons puzzles in the port's JSON save format |
| `player_data/` | Campaign progress and settings |
| `saves/` | Individual game saves for resuming puzzle arrangements |
| `.import_work/` | Importer diagnostics and locally generated data packs used by the standalone executable |

The decoded DOS and full Windows CD files together with their runtime packs take about 1.5 GiB, in addition to the executable and its support files. Media upgrades also need temporary working space.

To share a puzzle, save it in Home Toons and copy the JSON file into the other player's `player_data/user_levels/`. Reopen the Piggy Bank to see the level. You can add or edit these loose files without rebuilding the executable or packing them.

To reuse your portable debug installation, close the game and copy its complete `assets/` and optional `dlc_win_data/` directories beside `ftoons.exe`, including each directory's `ftoons-import.json`. ftoons builds its local packs on the next launch. You can also copy `player_data/` to carry over your saves.
