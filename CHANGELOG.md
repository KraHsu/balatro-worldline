# Changelog

## 0.6.8

- Discard the serialized menu/collection deck preview before checkpoint and Continue loads so Steamodded constructs card backs from the real selected deck, preventing `effect` errors during Undo.
- Keep the discarded preview out of restored gameplay data and branch/video comparisons. The selected deck, gameplay state and seeded RNG remain checked.
- Allow backup recovery after a partial native load leaves an unconstructed blind, and discard abandoned events before the menu fallback if both loads fail.
- Keep existing save and archive files unchanged; no migration is required.

## 0.6.7

- Prevent repeating native card-pulse events, such as DNA waiting for the first played hand, from indefinitely blocking stable snapshots and queued inputs.
- Mark only the events scheduled by native `juice_card_until`; unrelated nonblocking events still prevent recording at an unsafe boundary.
- Leave native pulse callbacks, timing, visual effects and RNG behavior unchanged.

## 0.6.6

- Store the deck ID in worldline metadata and summaries instead of copying the live Steamodded Back object, preventing `metadata[deck][inject]` function serialization errors when automatic recording starts.
- Read older object-shaped deck metadata and summaries as their deck IDs, restoring deck previews and localized names without changing gameplay snapshots or RNG state.
- Preserve the native reconstructed deck reference during Undo and convergence instead of replacing it with the save format's object placeholder.
- Keep strict rejection of unsupported values elsewhere. Existing archives need no manual migration.

## 0.6.5

- Queue fast player inputs until the previous animation reaches a stable boundary, preserving a separate Undo point for each completed action instead of clearing the history.
- Preserve queued card targets and hand selections; cancel stale inputs when their cards, blind or round change. Native event continuations still execute immediately.
- Show brief in-game feedback when Undo is unavailable, reaches a history boundary or fails to restore, in all 15 game languages.
- Correct copied negative Planet faces when native copies inherit discovery-bypass parameters after their sprites have been created.
- Rebuild Wheel of Fortune, Hex and Ectoplasm eligibility caches before restoring highlighted consumable controls, preventing `next(nil)` restore failures.
- Keep the existing archive format. This update does not require migration; previously missing session-only Undo entries cannot be reconstructed.

## 0.6.4

- Organize the WorldLine runtime into domain, runtime, storage, UI, video, platform and worker modules under `src/`.
- Use one module registry for native loading, ZIP installations and background workers.
- Use `WorldLine` as the Mod ID, install directory and data directory; provide a backed-up migration tool for older local archives and native save attachments.
- Build and validate separate manual-install and Thunderstore ZIPs in GitHub Actions.
- Record branching stage history, action-level Undo, bookmarks, linear folds, snapshot comparison and local sharing.
- Export native gameplay animations through a separate offline renderer, streaming raw frames into FFmpeg with a bounded queue.
- Allow incomplete action records to export with an order warning when their replay inputs are available.
- Preserve poker-hand enumeration, playing-card order and pre-action counters in new recordings; verify legacy routes with constrained identity translation and distinguish unused UI caches from gameplay changes.
- Continue recorded routes past the native victory overlay without timing out.
- Restore cashout reward details without evaluating rewards twice.
- Provide native Windows path pickers, 720p/1080p/2K video output and all 15 game languages.
