"""Prepare and explicitly launch an isolated, offline Balatro QA copy.

The installed game and its save files are read only (hashes are recorded). Every
write made by this helper stays under .tools/runtime-test. No process is killed.
"""
from __future__ import annotations

import argparse
import copy
import ctypes
from ctypes import wintypes
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile


PROJECT = Path(__file__).resolve().parent.parent
RUNTIME = PROJECT / ".tools" / "runtime-test"
IDENTITY = "WorldLineQA"
DEFAULT_TITLE = "WorldLine QA - isolated offline test"
PROJECT_MODS = ("WorldLine",)
DEFAULT_GAME = Path(os.environ.get('BALATRO_GAME_DIR',
    str(Path(os.environ.get('ProgramFiles(x86)', 'C:/Program Files (x86)')) / 'Steam/steamapps/common/Balatro')))
DEFAULT_SMODS = Path(os.environ.get('SMODS_DIR',
    str(Path(os.environ.get('APPDATA', str(Path.home() / 'AppData/Roaming'))) / 'Balatro/Mods/smods')))
ENGINE_DLLS = ("love.dll", "lua51.dll", "SDL2.dll", "OpenAL32.dll", "mpg123.dll",
               "msvcp120.dll", "msvcr120.dll", "winmm.dll")
FORBIDDEN_ENGINE = {"luasteam.dll", "steam_api64.dll", "steam_appid.txt", "https.dll"}


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def inside(path: Path) -> Path:
    """Resolve before any write, including when an existing parent is a link."""
    target, root = path.resolve(), RUNTIME.resolve()
    intended = (PROJECT / ".tools" / "runtime-test").absolute()
    if (root != RUNTIME.absolute() or root == PROJECT or
            not (root == intended or root.is_relative_to(intended))):
        raise RuntimeError("QA root must be a real directory under this project, not a link")
    if not target.is_relative_to(root):
        raise RuntimeError(f"Refusing a write outside the QA root: {target}")
    return target


def mkdir(path: Path) -> Path:
    path = inside(path)
    path.mkdir(parents=True, exist_ok=True)
    return path


def write(path: Path, data: bytes | str) -> None:
    path = inside(path)
    mkdir(path.parent)
    if isinstance(data, str):
        path.write_text(data, encoding="utf-8")
    else:
        path.write_bytes(data)


def write_json(path: Path, value: object) -> None:
    write(path, json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def file_inventory(root: Path, excluded: set[str] | None = None) -> dict:
    """Read metadata and hashes only; never load or decode a user's save data."""
    entries = {}
    if not root.exists():
        return entries
    excluded = {name.casefold() for name in excluded or ()}
    for base, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(name for name in dirs if name.casefold() not in excluded
                         and not (Path(base) / name).is_symlink()
                         and not (Path(base) / name).is_junction())
        for name in sorted(files):
            item = Path(base) / name
            if item.is_symlink() or item.is_junction():
                continue
            info = item.stat()
            entries[item.relative_to(root).as_posix()] = {
                "size": info.st_size, "mtime_ns": info.st_mtime_ns, "sha256": sha256(item)}
    return entries


def baseline(game: Path, user_saves: Path) -> dict:
    return {"created": now(), "game_root": str(game), "save_root": str(user_saves),
            "excluded_save_directories": ["Mods"],
            "game": file_inventory(game), "saves": file_inventory(user_saves, {"Mods"})}


def copy_tree(source: Path, destination: Path, ignored: set[str] | None = None) -> list[str]:
    if not source.is_dir():
        raise RuntimeError(f"Copy source directory is missing: {source}")
    ignored = {name.casefold() for name in ignored or ()}
    copied = []
    for base, dirs, files in os.walk(source, followlinks=False):
        for name in list(dirs):
            item = Path(base) / name
            if item.is_symlink() or item.is_junction():
                raise RuntimeError(f"Do not copy mod links into QA: {item}")
        dirs[:] = sorted(name for name in dirs if name.casefold() not in ignored)
        for name in sorted(files):
            if name.casefold() in ignored:
                continue
            item = Path(base) / name
            if item.is_symlink() or item.is_junction():
                raise RuntimeError(f"Do not copy mod links into QA: {item}")
            relative = item.relative_to(source)
            target = inside(destination / relative)
            mkdir(target.parent)
            shutil.copy2(item, target)
            copied.append(relative.as_posix())
    return copied


def lua_string(value: str | Path) -> str:
    return json.dumps(str(value).replace("\\", "/"), ensure_ascii=False)


def path_guard() -> str:
    return f"""-- Private QA filesystem boundary; never ship this with the mod.
local qa_root = {lua_string(RUNTIME)}
local qa_appdata = {lua_string(RUNTIME / 'appdata')}
local qa_mods = {lua_string(RUNTIME / 'Mods')}
local function qa_normalize(path)
    return tostring(path or ''):gsub('\\\\', '/'):gsub('/+$', ''):lower()
end
local function qa_within(path)
    local p, root = qa_normalize(path), qa_normalize(qa_root)
    return p == root or p:sub(1, #root + 1) == root .. '/'
end
assert(qa_normalize(os.getenv('APPDATA')) == qa_normalize(qa_appdata), 'QA APPDATA boundary failed')
assert(qa_normalize(os.getenv('LOVELY_MOD_DIR')) == qa_normalize(qa_mods), 'QA mod boundary failed')
assert(qa_within(love.filesystem.getSaveDirectory()), 'QA save directory escaped')
assert(qa_within(love.filesystem.getSourceBaseDirectory()), 'QA source directory escaped')
assert(love.filesystem.getIdentity() == '{IDENTITY}', 'QA identity mismatch')
"""


def replace_once(source: str, old: str, new: str, description: str) -> str:
    if source.count(old) != 1:
        raise RuntimeError(f"Expected exactly one native {description}; refusing an uncertain patch")
    return source.replace(old, new, 1)


def patched_game_files(archive: zipfile.ZipFile, harness: Path | None,
                       title: str = DEFAULT_TITLE) -> dict[str, bytes]:
    conf = f"""-- Private offline Balatro QA configuration.
_RELEASE_MODE = true
_DEMO = false
function love.conf(t)
    t.identity = '{IDENTITY}'
    t.appendidentity = false
    t.console = false
    t.title = {lua_string(title)}
    t.window.title = t.title
    t.window.width = 1600
    t.window.height = 900
    t.window.minwidth = 640
    t.window.minheight = 360
    t.window.fullscreen = false
    t.window.resizable = true
end
"""
    main = archive.read("main.lua").decode("utf-8").replace("\r\n", "\n")
    # Keep the original OS/require/init lines inside an unreachable block so
    # Steamodded's Lovely pattern patches still find their expected targets.
    main = replace_once(main, "\t--Steam integration\n\tlocal os = love.system.getOS()",
                        "\t--Steam integration\n\tif false then -- QA: Steam is deliberately unreachable\n\tlocal os = love.system.getOS()",
                        "Steam load block")
    main = replace_once(main, "\t--Set the mouse to invisible immediately, this visibility is handled in the G.CONTROLLER",
                        "\tend -- QA offline Steam block\n\tG.STEAM = nil\n"
                        f"\tlove.window.setTitle({lua_string(title)})\n\n"
                        "\t--Set the mouse to invisible immediately, this visibility is handled in the G.CONTROLLER",
                        "end of Steam load block")
    main = path_guard() + """
package.loaded.luasteam = nil
package.preload.luasteam = function() error('Steam is disabled in private QA', 0) end
""" + main
    if harness:
        main += f"""
-- Install the optional QA controls only after startup has loaded the mods.
local qa_original_load = love.load
function love.load(...)
    local result = qa_original_load(...)
    assert(G.STEAM == nil, 'Steam must remain disabled in QA')
    local qa = require('qa_harness')
    qa.install{{identity = '{IDENTITY}', root = {lua_string(RUNTIME)},
        control_root = {lua_string(RUNTIME)}, sourcebase = {lua_string(RUNTIME / 'engine')},
        savedir = {lua_string(RUNTIME / 'appdata' / IDENTITY)}}}
    return result
end
"""
    game = archive.read("game.lua").decode("utf-8").replace("\r\n", "\n")
    game = replace_once(game, "    self:init_window()", """    -- Private QA only: never take the user's fullscreen or audio settings.
    self.F_CRASH_REPORTS, self.F_HTTP_SCORES, self.F_DISCORD = false, false, false
    self.F_NO_ACHIEVEMENTS, self.F_SKIP_TUTORIAL, self.F_MUTE = true, true, true
    self.SETTINGS.crashreports = false
    self.SETTINGS.language = 'zh_CN'
    self.SETTINGS.skip_splash = 'Yes'
    self.SETTINGS.tutorial_complete = true
    self.SETTINGS.WINDOW.screenmode = 'Windowed'
    self.SETTINGS.SOUND.volume = 0
    self.SETTINGS.SOUND.music_volume = 0
    self.SETTINGS.SOUND.game_sounds_volume = 0
    self:init_window()""", "startup window setup")
    save_manager = path_guard() + archive.read("engine/save_manager.lua").decode("utf-8")
    # A thread initially exposes only love.thread. Load filesystem before checks.
    save_manager = "require('love.filesystem')\n" + save_manager
    files = {"conf.lua": conf.encode(), "main.lua": main.encode(), "game.lua": game.encode(),
             "engine/save_manager.lua": save_manager.encode()}
    if harness:
        files["qa_harness.lua"] = harness.read_bytes()
    return files


def build_executable(source: Path, destination: Path, harness: Path | None,
                     title: str = DEFAULT_TITLE) -> dict:
    original = source.read_bytes()
    stream = io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(original)) as archive:
        start = min(info.header_offset for info in archive.infolist())
        stream.write(original[:start])
        patches = patched_game_files(archive, harness, title)
        with zipfile.ZipFile(stream, "a", compression=zipfile.ZIP_DEFLATED) as output:
            for info in archive.infolist():
                output.writestr(copy.copy(info), patches.pop(info.filename, archive.read(info.filename)))
            for name, content in patches.items():
                output.writestr(name, content)
    write(destination, stream.getvalue())
    with zipfile.ZipFile(destination) as check:
        if check.testzip() is not None:
            raise RuntimeError("Private QA executable ZIP integrity failed")
    return {"sha256": sha256(destination), "pe_prefix_bytes": start}


def process_status() -> dict:
    record = inside(RUNTIME / "process.json")
    if not record.exists():
        return {"running": False, "reason": "No QA process has been launched by this helper"}
    value = json.loads(record.read_text(encoding="utf-8"))
    if os.name != "nt":
        return {"running": None, "pid": value["pid"], "reason": "Windows process query is unavailable"}
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.OpenProcess(0x1000 | 0x100000, False, int(value["pid"]))
    if not handle:
        error = ctypes.get_last_error()
        return {"running": False if error == 87 else None, "pid": value["pid"],
                "reason": "Recorded QA PID no longer exists" if error == 87 else "Cannot safely query the recorded QA PID"}
    try:
        size, buffer = wintypes.DWORD(32768), ctypes.create_unicode_buffer(32768)
        if not kernel.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)):
            return {"running": None, "pid": value["pid"], "reason": "Cannot verify the recorded process image"}
        expected = inside(RUNTIME / "engine" / f"{IDENTITY}.exe")
        same = Path(buffer.value).resolve() == expected
        return {"running": bool(same and kernel.WaitForSingleObject(handle, 0) == 258),
                "pid": value["pid"], "image_matches_qa": same, "image": buffer.value}
    finally:
        kernel.CloseHandle(handle)


def prepare(args: argparse.Namespace) -> dict:
    selected_mods = tuple(getattr(args, "mods", None) or ("WorldLine",))
    if (not selected_mods or len(set(selected_mods)) != len(selected_mods) or
            any(name not in PROJECT_MODS for name in selected_mods)):
        raise RuntimeError("Only the named project mods may be copied into QA")
    title = getattr(args, "title", None) or DEFAULT_TITLE
    if not isinstance(title, str) or len(title) > 120 or any(ord(char) < 32 for char in title):
        raise RuntimeError("QA title must be a single line of at most 120 characters")
    for name in selected_mods:
        source = PROJECT / "src"
        if not (source / (name + ".json")).is_file() or not (source / "main.lua").is_file():
            raise RuntimeError(f"Project mod source is missing: {name}")
    mkdir(RUNTIME)
    if process_status().get("running") is not False:
        raise RuntimeError("A QA process may still be running; do not rebuild its files")
    game, smods = args.game_dir.resolve(), args.smods_dir.resolve()
    if not (game / "Balatro.exe").is_file() or not (smods / "src" / "core.lua").is_file():
        raise RuntimeError("Installed game or Steamodded source not found")
    user_saves = Path(args.user_saves).resolve() if args.user_saves else Path(os.environ["APPDATA"]) / "Balatro"
    if user_saves.resolve().is_relative_to(RUNTIME.resolve()):
        raise RuntimeError("Run prepare from the ordinary parent environment, not the QA process environment")
    baseline_path = inside(RUNTIME / "baseline.json")
    if not baseline_path.exists():
        write_json(baseline_path, baseline(game, user_saves))
    else:
        existing = json.loads(baseline_path.read_text(encoding="utf-8"))
        if (Path(existing["game_root"]).resolve() != game or
                Path(existing["save_root"]).resolve() != user_saves.resolve()):
            raise RuntimeError("Existing QA baseline belongs to different original paths; it was not overwritten")
    engine, mods = mkdir(RUNTIME / "engine"), mkdir(RUNTIME / "Mods")
    permitted_mods = {"smods", "lovely", *selected_mods}
    if selected_mods == ("WorldLine",):
        permitted_mods.add("WorldLineQAHarness")
    unexpected = [p.name for p in mods.iterdir() if p.name not in permitted_mods]
    if unexpected:
        raise RuntimeError("Unexpected QA mods exist; refusing to load them: " + ", ".join(unexpected))
    for name in FORBIDDEN_ENGINE:
        if (engine / name).exists():
            raise RuntimeError(f"Unexpected Steam/HTTP library in private engine: {name}")
    for name in ENGINE_DLLS:
        source, destination = game / name, inside(engine / name)
        if not source.is_file():
            raise RuntimeError(f"Missing engine dependency: {name}")
        shutil.copy2(source, destination)
    harness = args.harness.resolve() if args.harness else None
    if harness and not harness.is_file():
        raise RuntimeError("QA harness file is missing")
    executable = inside(engine / f"{IDENTITY}.exe")
    built = build_executable(game / "Balatro.exe", executable, harness, title)
    copied_smods = copy_tree(smods, mods / "smods", {".git", "__pycache__"})
    logging = inside(mods / "smods" / "src" / "preflight" / "logging.lua")
    logging_source = logging.read_text(encoding="utf-8")
    logging_source = replace_once(logging_source, "\ninitializeSocketConnection()\n",
                                  "\n-- QA: no connection to the user's debug server.\n",
                                  "Steamodded debug socket startup")
    write(logging, logging_source)
    copied_mods = {name: copy_tree(PROJECT / "src", mods / name, {".git", "__pycache__"})
                   for name in selected_mods}
    for directory in ("appdata", "localappdata", "temp", f"appdata/{IDENTITY}"):
        mkdir(RUNTIME / directory)
    manifest = {"prepared": now(), "identity": IDENTITY, "root": str(RUNTIME),
                "executable": str(executable), "cwd": str(engine), "exe": built,
                "harness": str(harness) if harness else None,
                "harness_sha256": sha256(harness) if harness else None,
                "title": title, "mods": list(selected_mods),
                "smods_files": len(copied_smods),
                "mod_files": sum(len(files) for files in copied_mods.values()),
                "mod_file_counts": {name: len(files) for name, files in copied_mods.items()},
                "engine_files": {name: sha256(engine / name) for name in ENGINE_DLLS},
                "safety": {"steam_disabled": True, "http_disabled": True,
                           "debug_socket_disabled": True, "windowed": True, "muted": True}}
    write_json(RUNTIME / "manifest.json", manifest)
    return {"prepared": True, "root": str(RUNTIME), "executable": str(executable),
            "identity": IDENTITY, "mods": list(selected_mods),
            "harness": bool(harness), "launched": False}


def launch(args: argparse.Namespace) -> dict:
    if os.name != "nt":
        raise RuntimeError("The private copied engine is for Windows only")
    if process_status().get("running") is not False:
        raise RuntimeError("The recorded QA process may already be running")
    manifest = json.loads(inside(RUNTIME / "manifest.json").read_text(encoding="utf-8"))
    executable = inside(RUNTIME / "engine" / f"{IDENTITY}.exe")
    if sha256(executable) != manifest["exe"]["sha256"]:
        raise RuntimeError("QA executable changed after prepare; run prepare again")
    engine = inside(executable.parent)
    for name in FORBIDDEN_ENGINE:
        if (engine / name).exists():
            raise RuntimeError(f"Refusing to launch with forbidden private engine file: {name}")
    env = dict(os.environ)
    for key, folder in {"APPDATA": "appdata", "LOCALAPPDATA": "localappdata",
                        "TEMP": "temp", "TMP": "temp", "LOVELY_MOD_DIR": "Mods"}.items():
        env[key] = str(mkdir(RUNTIME / folder))
    # No Steam launcher, no Steam environment, no global/setx mutations.
    for key in list(env):
        if key.casefold().startswith("steam"):
            env.pop(key)
    output = inside(RUNTIME / "process.log")
    with output.open("ab") as stream:
        process = subprocess.Popen([str(executable)], cwd=str(engine), env=env,
                                   stdin=subprocess.DEVNULL, stdout=stream, stderr=stream,
                                   creationflags=subprocess.CREATE_NO_WINDOW)
    record = {"pid": process.pid, "launched": now(), "executable": str(executable),
              "identity": IDENTITY, "env": {key: env[key] for key in
                  ("APPDATA", "LOCALAPPDATA", "TEMP", "TMP", "LOVELY_MOD_DIR")}}
    write_json(RUNTIME / "process.json", record)
    result = {"launched": True, "pid": process.pid, "executable": str(executable)}
    if args.wait:
        # Keep the tool's job alive while the native window is under test.
        print(json.dumps(result), flush=True)
        result["exit_code"] = process.wait()
    return result


def verify(args: argparse.Namespace) -> dict:
    before = json.loads(inside(RUNTIME / "baseline.json").read_text(encoding="utf-8"))
    changed = {}
    for name, root, excluded in (("game", Path(before["game_root"]), set()),
                                  ("saves", Path(before["save_root"]), {"Mods"})):
        current, old = file_inventory(root, excluded), before[name]
        changed[name] = {"added": sorted(set(current) - set(old)),
                         "removed": sorted(set(old) - set(current)),
                         "changed": sorted(key for key in set(old) & set(current)
                                           if old[key]["sha256"] != current[key]["sha256"])}
    clean = all(not paths for group in changed.values() for paths in group.values())
    result = {"verified": now(), "original_files_unchanged": clean, "differences": changed,
              "note": "The original game may be running; differences alone do not identify their author.",
              "qa_process": process_status()}
    write_json(RUNTIME / "verification.json", result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    prep = subcommands.add_parser("prepare", help="Copy and patch only the private QA directory; never launch")
    prep.add_argument("--game-dir", type=Path, default=DEFAULT_GAME)
    prep.add_argument("--smods-dir", type=Path, default=DEFAULT_SMODS)
    prep.add_argument("--user-saves", type=Path)
    prep.add_argument("--harness", type=Path)
    prep.add_argument("--mods", nargs="+", choices=PROJECT_MODS, default=["WorldLine"],
                      help="Project mods to copy; default preserves WorldLine QA")
    prep.add_argument("--title", help="Private QA window title; does not affect the installed game")
    start = subcommands.add_parser("launch", help="Explicitly start the prepared QA executable only")
    start.add_argument("--wait", action="store_true", help="Keep the parent process alive for the interactive test")
    subcommands.add_parser("status", help="Read the recorded QA PID without manipulating any process")
    subcommands.add_parser("verify", help="Compare original metadata/hashes to the initial baseline")
    args = parser.parse_args()
    try:
        result = {"prepare": prepare, "launch": launch, "status": lambda _: process_status(), "verify": verify}[args.command](args)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (OSError, RuntimeError, ValueError, zipfile.BadZipFile) as error:
        print(f"QA helper stopped: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
