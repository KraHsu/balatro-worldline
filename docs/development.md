# Development

[README](../README.md) · [Architecture](architecture.md) · [Contributing](../CONTRIBUTING.md)

## Prerequisites

Use Python 3.13. Offline tests require Lupa 2.6 and Steamodded's JSON library, not a game installation.

```sh
python -m pip install -r requirements-dev.txt
git clone https://github.com/Steamodded/smods.git .deps/Steamodded
git -C .deps/Steamodded checkout af0fdb1eb2c9e191262c128bc88bbc4da991e12d
python tools/test.py
```

Alternatively pass `--json-library /path/to/smods/libs/json/json.lua`, or set `SMODS_JSON_LIBRARY`. Each Lua suite runs in an isolated Lua 5.1 and LuaJIT instance. Python tests cover packaging and migration.

## Build

```sh
python tools/build.py
python tools/test.py --check-packages
```

The default builds both `dist/WorldLine-<version>.zip` and `dist/WorldLine-<version>-Thunderstore.zip`. Use `--target manual` or `--target thunderstore` for one. PowerShell users can run `./build.ps1 -Target all`.

An explicit allowlist selects runtime files from `src/`. Every runtime payload is under `WorldLine/` in both ZIPs. The Thunderstore package also contains its root manifest, generated English README, changelog, icon, MIT license and attribution. The single source icon is `src/assets/1x/modicon.png`. Game files, dependencies, profiles, logs, tests and development environments are excluded.

Fixed entry order, timestamps, permissions and stored ZIP entries make identical source bytes produce identical packages across platforms. Runtime and Thunderstore versions must agree.

## GitHub Actions

Pushes, pull requests and manual dispatch run the same build and validation. The workflow uploads the manual ZIP and Thunderstore ZIP separately, after tests pass, with 30-day retention. Artifacts are uploaded as the ZIP files themselves rather than another nested archive. Download them from the latest successful **Test and package** run.

The workflow uses read-only repository permissions and pinned action commits. Publishing the Thunderstore package remains a separate upload to the Balatro community. Existing package versions cannot be overwritten; increase the version first.

## Isolated game testing

The public helper only writes below `.tools/runtime-test`, records original-file hashes, disables Steam/HTTP/debug sockets and refuses unexpected QA mods. It never terminates the installed game.

```powershell
python tools/runtime_test.py prepare --game-dir "D:/Games/Balatro" --smods-dir "$env:APPDATA/Balatro/Mods/smods"
python tools/runtime_test.py launch --wait
python tools/runtime_test.py verify
```

Only use your purchased game and installed loaders. Do not commit the copied runtime. For engine-facing changes, exercise restore into hand/shop/pack/cashout states, purchases and repeated Undo, UI input ownership, shaders, video completion/cancellation and restart. Check visible game identity, archive cursor and RNG after exporting.

## Legacy data migration

Version 0.6.4 uses the `WorldLine` Mod ID, directory, data identifiers and `.worldline.json` sharing suffix. To upgrade from 0.6.3 or earlier, close Balatro and prepare a backed-up conversion:

```powershell
python tools/migrate_legacy.py --data-dir "$env:APPDATA/Balatro" --backup-dir "D:/Backups/WorldLine-upgrade" --apply
```

Without `--apply`, the tool only stages converted files and writes a migration report. Apply that prepared conversion later with `python tools/migrate_legacy.py --apply-report /path/to/backup/migration.json`. Choose a new backup directory outside game data. Original bytes and SHA-256 values are retained. It converts both archive generations, bookmarks/folds/resume data, backup/import/export JSON, native run attachments and Mod settings. Native save text is edited only for owned identifiers, then recompressed as raw deflate; it is not executed or regenerated as floating-point values. New or changed save files since preparation abort migration; replacement failures restore the original files.

After conversion, remove the old Mod folder/ZIP and install one current `WorldLine` package. Do not run the old Mod against migrated data. Existing cache/video directories are retained by the directory rename. Historical snapshots without recorded input/order metadata remain marked as legacy; migration does not invent missing actions.

## Repository conventions

Keep runtime code in the subsystem that owns its effects. Add module paths to `src/loader.lua`, mirror tests under `tests/`, and update the runtime allowlist only for a new supported asset location. `CODE_VERSION` identifies the release; the archive protocol version is maintained independently. See [Contributing](../CONTRIBUTING.md).
