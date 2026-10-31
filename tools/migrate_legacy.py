"""Back up and migrate pre-0.6.4 WorldLine data without executing save code.

The default prepares a conversion only. Close Balatro before using --apply.
Native saves keep their original Lua text and raw-deflate container format;
only WorldLine-owned identifiers are replaced. Player progress and RNG stay intact.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import zlib

OLD_ROOT = "BalatroTree"
NEW_ROOT = "WorldLine"
FIELDS = ("run_id", "node_id", "recording_suspended", "suspended_pool")


def convert_text(value: str) -> str:
    if value == "btree-data":
        return "worldline-data"
    if value == "balatro-tree":
        return "worldline"
    if value == OLD_ROOT:
        return NEW_ROOT
    if value.startswith("btree_"):
        return "worldline_" + value[6:]
    if value.startswith(OLD_ROOT + "/"):
        value = NEW_ROOT + value[len(OLD_ROOT):]
    return value.replace(".btree.json", ".worldline.json")


def convert_json(data: bytes) -> bytes:
    def visit(value):
        if isinstance(value, str):
            return convert_text(value)
        if isinstance(value, list):
            return [visit(item) for item in value]
        if isinstance(value, dict):
            result = {convert_text(key): visit(item) for key, item in value.items()}
            if len(result) != len(value):
                raise ValueError("Migration would merge dictionary keys")
            return result
        return value
    if len(data) > 128 * 1024 * 1024:
        raise ValueError("Archive exceeds the supported size")
    return json.dumps(visit(json.loads(data)), ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def convert_native(data: bytes) -> bytes:
    try:
        text = zlib.decompress(data, -15)
        compressed = True
    except zlib.error:
        if not data.lstrip().startswith(b"return"):
            raise ValueError("Unknown native save encoding")
        text, compressed = data, False
    original = text
    for name in FIELDS:
        text = text.replace(("btree_" + name).encode(), ("worldline_" + name).encode())
    text = text.replace(b"BalatroTree", b"WorldLine")
    if text == original:
        return data
    if not compressed:
        return text
    encoder = zlib.compressobj(level=1, wbits=-15)
    return encoder.compress(text) + encoder.flush()


def game_is_running() -> bool:
    if os.name != "nt":
        return False
    result = subprocess.run(["tasklist", "/FI", "IMAGENAME eq Balatro.exe", "/FO", "CSV", "/NH"],
                            capture_output=True, text=True, errors="replace", check=True,
                            creationflags=0x08000000)
    return any(row and row[0].casefold() == "balatro.exe" for row in csv.reader(io.StringIO(result.stdout)))


def candidates(data_dir: Path) -> list[Path]:
    legacy = data_dir / OLD_ROOT
    files = [p for p in legacy.rglob("*.json")
             if p.relative_to(legacy).parts[0] not in ("render-jobs", "recordings")]
    files += list(data_dir.glob("[0-9]*/save.jkr"))
    config = data_dir / "config" / (OLD_ROOT + ".jkr")
    if config.exists():
        files.append(config)
    return sorted(files)


def target_name(relative: str) -> str:
    if relative == "config/" + OLD_ROOT + ".jkr":
        return "config/" + NEW_ROOT + ".jkr"
    return relative.replace(OLD_ROOT + "/", NEW_ROOT + "/", 1).replace(".btree.json", ".worldline.json")


def contained(root: Path, relative: str) -> Path:
    path = root / relative
    if not relative or Path(relative).is_absolute() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError("Migration path is outside its data or backup directory")
    for parent in (path, *path.parents):
        if parent == root:
            break
        if parent.is_symlink():
            raise ValueError("Migration paths must not be symbolic links")
    return path


def prepare(data_dir: Path, backup_dir: Path) -> dict:
    data_dir, backup_dir = data_dir.resolve(), backup_dir.resolve()
    legacy = data_dir / OLD_ROOT
    if not legacy.is_dir() or (data_dir / NEW_ROOT).exists():
        raise ValueError("Expected only the legacy data directory; refusing to merge or overwrite WorldLine data")
    if backup_dir.exists() or backup_dir.is_relative_to(data_dir):
        raise ValueError("Choose a new backup directory outside the game data directory")
    records = []
    backup_dir.mkdir(parents=True)
    for source in candidates(data_dir):
        if source.is_symlink() or not source.resolve().is_relative_to(data_dir):
            raise ValueError(f"Cannot migrate a linked path: {source}")
        relative = source.relative_to(data_dir).as_posix()
        content = source.read_bytes()
        converted = convert_json(content) if source.suffix == ".json" else convert_native(content)
        target = target_name(relative)
        original, staged = backup_dir / "original" / relative, backup_dir / "converted" / target
        original.parent.mkdir(parents=True, exist_ok=True)
        staged.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, original)
        staged.write_bytes(converted)
        records.append({"source": relative, "target": target,
                        "sha256": hashlib.sha256(content).hexdigest(),
                        "converted_sha256": hashlib.sha256(converted).hexdigest()})
    report = {"data_dir": str(data_dir), "backup_dir": str(backup_dir), "state": "prepared", "files": records}
    (backup_dir / "migration.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    return report


def apply(report: dict) -> None:
    if game_is_running():
        raise RuntimeError("Close Balatro before applying the migration")
    data_dir, backup_dir = Path(report["data_dir"]).resolve(), Path(report["backup_dir"]).resolve()
    if report["state"] != "prepared" or (data_dir / NEW_ROOT).exists():
        raise ValueError("Migration is already applied or the destination exists")
    if backup_dir.is_relative_to(data_dir) or not (data_dir / OLD_ROOT).is_dir():
        raise ValueError("Invalid migration directories")
    sources = [item["source"] for item in report["files"]]
    current = [p.relative_to(data_dir).as_posix() for p in candidates(data_dir)]
    if sorted(sources) != sorted(current) or len(set(sources)) != len(sources):
        raise RuntimeError("Save files changed after preparation; prepare a fresh migration")
    for item in report["files"]:
        source = contained(data_dir, item["source"])
        if item["target"] != target_name(item["source"]):
            raise ValueError("Unexpected migration target")
        contained(data_dir, item["target"])
        original = contained(backup_dir / "original", item["source"])
        staged = contained(backup_dir / "converted", item["target"])
        if hashlib.sha256(original.read_bytes()).hexdigest() != item["sha256"]:
            raise RuntimeError("Original backup changed after preparation")
        if hashlib.sha256(source.read_bytes()).hexdigest() != item["sha256"]:
            raise RuntimeError("Save files changed after preparation; prepare a fresh migration")
        if hashlib.sha256(staged.read_bytes()).hexdigest() != item["converted_sha256"]:
            raise RuntimeError("Staged conversion changed after preparation")
    moved = False
    temporary_files = []
    try:
        (data_dir / OLD_ROOT).rename(data_dir / NEW_ROOT)
        moved = True
        for item in report["files"]:
            target = data_dir / item["target"]
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_name(target.name + ".migration-tmp")
            temporary_files.append(temporary)
            temporary.write_bytes((backup_dir / "converted" / item["target"]).read_bytes())
            temporary.replace(target)
            previous = data_dir / item["source"].replace(OLD_ROOT + "/", NEW_ROOT + "/", 1)
            if previous != target and previous.exists():
                previous.unlink()
        report["state"] = "applied"
    except Exception:
        for temporary in temporary_files:
            if temporary.exists():
                temporary.unlink()
        if moved:
            (data_dir / NEW_ROOT).rename(data_dir / OLD_ROOT)
        for item in report["files"]:
            original = data_dir / item["source"]
            original.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(backup_dir / "original" / item["source"], original)
            renamed = data_dir / item["target"].replace(NEW_ROOT + "/", OLD_ROOT + "/", 1)
            if renamed != original and renamed.exists():
                renamed.unlink()
        raise
    finally:
        (backup_dir / "migration.json").write_text(json.dumps(report, indent=2), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path)
    parser.add_argument("--backup-dir", type=Path)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--apply-report", type=Path, help="Apply an existing prepared migration report")
    args = parser.parse_args()
    if args.apply_report:
        if args.data_dir or args.backup_dir or args.apply:
            parser.error("Use --apply-report on its own")
        report = json.loads(args.apply_report.read_text(encoding="utf-8"))
        apply(report)
    else:
        if not args.data_dir or not args.backup_dir:
            parser.error("Provide both --data-dir and --backup-dir")
        report = prepare(args.data_dir, args.backup_dir)
        if args.apply:
            apply(report)
    print(json.dumps({"state": report["state"], "files": len(report["files"]), "backup": report["backup_dir"]}))


if __name__ == "__main__":
    main()
