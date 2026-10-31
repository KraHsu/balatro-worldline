# Contributing

WorldLine is a Balatro mod by KraHsu, licensed under MIT. Bug reports, documentation fixes and focused pull requests are welcome.

## Development

Use Python 3.13 and the dependencies in `requirements-dev.txt`. Follow [the development guide](docs/development.md) for the pinned Steamodded JSON library, tests, package generation and isolated game testing.

Run `python tools/build.py` and `python tools/test.py --check-packages` before submitting a change. The test suite exercises Lua 5.1 and LuaJIT. Changes to native UI, restore logic or the renderer also need an isolated real-game check; unit tests do not establish compatibility with the game engine.

## Code boundaries

- Keep tree and branch rules in `src/domain/`; these modules do not access native game objects or files.
- Capture or restore game objects through `src/runtime/snapshot.lua` and its adapters.
- Keep filesystem operations in storage/platform modules and bounded worker protocols.
- Build view data from saved snapshots. Drawing and hover information must not consume gameplay RNG.
- Load modules and worker sources through `src/loader.lua`; keep paths out of business logic.
- Preserve immutable checkpoints and pending saves. Treat imported archives as data, never Lua programs.

Keep changes scoped and explain the trigger, resulting behavior and validation in the pull request. Include a meaningful regression case when fixing state, RNG or persistence behavior. Use the existing editor configuration and avoid unrelated formatting changes.

## Reports and assets

For a bug, include game, Steamodded, Lovely and WorldLine versions; reproduction steps; expected and actual behavior; and the relevant error. For replay problems, include the route endpoints. A shared archive can contain custom names and bookmarks, so review it before attaching it publicly.

Do not submit game executables, DLLs, extracted game assets, real profiles, local logs, generated video or debugging environments. Runtime art comes from each user's purchased game. Keep only maintained screenshots and original project branding in documentation.
