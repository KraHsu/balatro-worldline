# Usage

[README](../README.md) · [简体中文](usage_cn.md)

Start a normal run. WorldLine creates a history at the first stable state by default; no manually entered seed is required. Change automatic creation through **Options → WorldLine settings**. Enabling recording midway starts at the current state.

## Navigate

- Press **F6** or use **Options → WorldLine** to open the graph.
- Right-drag to pan; wheel to zoom. The minimap supports dragging and pointer-centered zoom.
- Left-drag to box-select, Ctrl-click to add, or Shift-click to select a path.
- Select a checkpoint and choose **Converge here** to restore it.
- Select two nodes for **Compare** or for a recording route.

Nodes mark stage entries. Connecting lines summarize choices within that stage, including purchases, sales, refreshes, packs and hands. Plays/discards and individual shop actions do not create separate graph nodes. Repeating the same ordered inputs and complete state can reuse a branch.

Bookmarks can name important checkpoints. A fold preserves its endpoint cards and hides a linear interior inside a dashed region. Folds cannot cross a fork. The minimap, bookmark browser and folds help navigate large histories.

## Undo and progress

**Ctrl+Z** undoes the last irreversible operation; selecting a card does not count. Undo retains already visited branches. The first ordinary Undo does not add WorldLine's seeded restriction. In an unseeded run, another consecutive Undo asks for confirmation: press again within two seconds to confirm. Seeded runs need no confirmation.

Using the graph or its restore/share/archive features marks the run seeded, following vanilla achievement/discovery restrictions. Passive recording and changing automatic-creation settings do not. Restoring an old checkpoint cannot remove a restriction already applied.

## Local data

Data lives under `%APPDATA%/Balatro/WorldLine` on Windows. Archives use two generations for recovery. Archive management supports renaming, verified backups, deleting histories or branches, and exporting a branch with its causal route. Deleting creates a backup first. Restoring a backup makes a new history.

**Share export** creates `.worldline.json`; recipients can drop it into the game window or put it in `WorldLine/imports` and choose Import. Use matching game/loader/Mod versions. Use the [migration tool](development.md#legacy-data-migration) for records created before 0.6.4.

## Video

Select an ancestor and a descendant, then choose **Record video**. Choose an external FFmpeg executable and an output folder with the Windows pickers or **Enter path**. Manual text input supports held Backspace, Unicode and paste.

Configure 0.25–8x game speed, 30/60 FPS, 720p/1080p/2K resolution, action delay, consumable previews and pack-card previews. 2K increases GPU memory, encoding work and output size. An empty output folder uses `WorldLine/recordings` in game data.

Export pauses the current run, shows progress and renders in a separate offline process. Esc cancels. Output is silent H.264 MP4. Rendering and encoding overlap without PNG intermediates; short clips still include process-startup time.

Incomplete historical action records show an order warning and remain exportable if their inputs exist. Replay errors identify the stage and field that differ. Missing target cards or gameplay/RNG divergence stop playback. An unused orbital cache in a legacy route with no blind skips can differ without changing its actions; it is covered by the legacy warning.

Export does not move the current worldline cursor or add branches. Regular exit waits for pending saves; force-closing the game can lose unsaved progress.
