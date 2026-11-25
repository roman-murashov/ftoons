# ftoons portable debug project with Head-2-head puzzles in Home Toons

Extract the project into a writable folder on 64-bit Windows. Open `project.godot` in **Godot 4.7** and press **F5**. Godot is the only application you need to install. The project includes its disc, graphics and audio decoders and works offline.

## Import your game

1. Select your **DOS** installation folder or a ZIP containing it. The supported release contains `TOONS.EXE`, `RESOURCE.001` and `ADL.DRV` together. The importer verifies the files, builds the 100 campaign levels and renders DOS music and effects using the original sound bank and driver.
2. For the **Windows game**, select **Disc or ZIP…** and open the original CD's CUE, BIN or ISO directly. You can also select an installed game folder, an extracted CD folder or a ZIP. Keep the BIN beside its CUE. The verified original mixed-mode BIN can also be opened on its own.
3. Click **Import and open debug game**. The six debug tabs open with CAKE1 selected in Puzzles. Sound effects are enabled. Music starts muted and can be turned on in Game emulation. The initial Home Toons list omits PUZ_800, PUZ_801 and PUZ_802.

Windows and MPC refer to the same Windows game. The features available depend on which parts of its media you supply.

| Windows input | What it enables |
| --- | --- |
| Installed files including `TOONRSRC.DLL` | Windows sprite pack, sound resources and 50 Head-2-head puzzles. Loose MIDI files are also imported when present. |
| CD data track as an ISO, or extracted files including the intro resources and matching executable | Also enables the voiced pre-level animations. A conventional data-only ISO contains the game files and intro speech. CD music is recorded in separate audio tracks. |
| Original mixed-mode BIN, or its CUE with the matching BIN | Supplies both the game files and all 24 CD audio tracks. Use **MIDI/CD Music** in Game emulation to switch music. **Intro videos** controls the animations independently. |

To add the disc after importing installed files or a data-only ISO, open **Resources → Add Windows CD media…**. This preserves the files from the first import. The Resources tab displays the number of available CD tracks and voiced intro clips.

## Play the Windows puzzles solo

In **Game emulation**, open the remote control, click the **Piggy Bank** load arrow and choose **Home Toons**, the fifth category. After importing the Windows game, the list includes all 50 Head-2-head puzzles by their original titles in PLAY1–PLAY50 order. Saved Home Toons appear before the Windows series. Select a title and click **Load**.

Place gadgets and press **Play** as in the DOS campaign. The original Windows goal decides when the puzzle is solved. **Next puzzle** on the reward screen advances within the Windows series through PLAY50. For timed turns and tournaments, use the **Head-2-head mode** tab.

## Where the files go

All paths below are relative to the folder containing `project.godot`. You can inspect and back up the loose files or move the entire project to another folder.

The DOS import occupies about 208 MiB. The full Windows disc adds about 557 MiB. Allow extra space for the Godot editor's import cache and for temporary files when adding or replacing media.

| Folder | Contents |
| --- | --- |
| `assets/original/` | DOS archive payloads, graphics and palette resources, decoded audio, music, runtime tables and catalogs |
| `assets/levels/` | 100 decoded campaign levels in JSON |
| `assets/decoded_graphics/` and `dlc_win_data/decoded_graphics/` | Decoded PNG sprite sheets, screen images and JSON frame layouts. Empty frames and original frame origins remain available in the layouts. |
| `dlc_win_data/` | Windows resources in `graphics/`, `intros/`, `audio/` and `head_to_head/`. CD WAV files are in `audio/cd/`. |
| `player_data/` | Preferences, campaign progress and authored Home Toons under `user_levels/` |
| `.import_work/` | Project-local temporary files and importer diagnostics |

Each completed import has an `ftoons-import.json` record inside `assets/` or `dlc_win_data/`. Later launches check the files and open the game from that copy. To rebuild an edition, close the game and move its generated directory outside the project before the next launch. Keep `player_data/` to preserve progress. The older Python-based debug project's AppData cache is independent.

The distributed project contains code, decoder libraries and port metadata. It acquires the original media on your machine. `port_data/` supplies the authored metadata used during installation. Original game animation and sprite formats are decoded by Godot's existing playback code as needed.
