"""Persistent, invalidated audio/waveform caches for the stinger workbench."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import soundfile as sf

from .common import CliError
from .game import game_root_for, resolve_game_dir

CACHE_VERSION = 8


def _signature(path):
    path = Path(path)
    try:
        stat = path.stat()
        return [str(path.resolve()), stat.st_size, stat.st_mtime_ns]
    except FileNotFoundError:
        return [str(path.resolve()), None]


def _key(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def valid_pcm(path, frames=None):
    try:
        info = sf.info(path)
        return (
            info.samplerate == 48000
            and info.channels == 2
            and info.frames > 0
            and (frames is None or info.frames == frames)
        )
    except (OSError, RuntimeError):
        return False


def catalog_key(project, game, locale, current_game):
    from .stingers import load_plan, local_file, plan_path

    root = game_root_for(game)
    paths = [plan_path(project)]
    for base in (root / "media", root / "mediapc"):
        paths.append(base / "audio/FMODBanks")
        paths.append(base / "audio" / f"RadioInfo_{locale}.xml")
        for number in range(1, 10):
            paths.append(base / "audio/FMODBanks" / f"R{number}_Stingers_{locale}.assets.bank")
    plan = load_plan(project)
    for baseline in plan["baselines"].values():
        paths += [local_file(project, baseline[k]) for k in ("bank_ref", "xml_ref")]
    for asset in plan["assets"]:
        paths.append(local_file(project, asset["source"]))
    for name in ("sources", "siren"):
        folder = project / name
        if folder.exists():
            paths += [
                p
                for p in folder.rglob("*")
                if p.is_file()
                and not any(
                    p.is_relative_to(project / "sources" / kind) for kind in ("stingers", "voices")
                )
            ]
    return _key(
        [
            CACHE_VERSION,
            str(project.resolve()),
            str(root.resolve()),
            locale,
            current_game,
            [_signature(p) for p in paths],
        ]
    )


def _read(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def cached_catalog(project, game, locale, *, current_game=False):
    from .stingers import _read_catalog, _write, locale_code

    locale = locale_code(locale)
    key = catalog_key(project, game, locale, current_game)
    path = project / "analysis/stingers/catalog" / f"{locale}-{int(current_game)}.json"
    cached = _read(path)
    if cached and cached.get("key") == key:
        return cached["data"]
    data = _read_catalog(project, game, locale, current_game=current_game)
    _write(path, {"key": key, "data": data})
    return data


def cached_wave(path):
    from .stingers import _read_wave, _write

    path = Path(path)
    destination = path.with_suffix(path.suffix + ".wave.json")
    key = _key([CACHE_VERSION, _signature(path)])
    cached = _read(destination)
    if cached and cached.get("key") == key:
        return {**cached["data"], "path": str(path)}
    data = _read_wave(path)
    _write(destination, {"key": key, "data": data})
    return data


def asset_source(args, project, asset, *, namespace="stingers"):
    from .stingers import _run, _tool, digest, local_file

    source = local_file(project, asset["source"])
    if namespace not in {"stingers", "voices"}:
        raise CliError("无效的音频缓存目录")
    output = project / "analysis" / namespace / "assets" / f"{asset['sha256']}.wav"
    # The output is project-owned; source files and game banks are never rewritten.
    if not valid_pcm(output):
        if digest(source) != asset["sha256"]:
            raise CliError("台呼素材已改变，请重新导入")
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = output.with_suffix(".tmp.wav")
        try:
            _run(
                [
                    _tool(args, "ffmpeg"),
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-nostdin",
                    "-y",
                    "-i",
                    source,
                    "-ac",
                    2,
                    "-ar",
                    48000,
                    "-c:a",
                    "pcm_s16le",
                    temporary,
                ]
            )
            with sf.SoundFile(temporary) as audio:
                if audio.samplerate != 48000 or audio.channels != 2 or len(audio) == 0:
                    raise CliError("素材缓存格式不正确")
            temporary.replace(output)
        finally:
            temporary.unlink(missing_ok=True)
    return cached_wave(output)


def edited_preview(args, project, plan, edit):
    from .stingers import _asset, local_file, render, validate_edit

    values, frames, next_sample = validate_edit(plan, {}, edit)
    asset = _asset(plan, values["asset_id"])
    source = local_file(project, asset["source"])
    import copy
    import math

    gain = float(edit.get("build_gain_db", 0))
    if not math.isfinite(gain) or not -6 <= gain <= 6:
        raise CliError("台呼统一增益需在 -6 至 +6 dB")
    key = _key([CACHE_VERSION, values, gain, asset["sha256"], _signature(source)])
    output = project / "analysis/stingers/previews" / f"{key}.wav"
    if not valid_pcm(output, frames):
        import argparse

        render_args = copy.copy(args) if args is not None else argparse.Namespace()
        render_args._stinger_render_gain_db = gain
        render(render_args, project, plan, {}, values, output)
    return {**cached_wave(output), "next_track": next_sample / 48000, "edit": values}


def warm_cache(args, project):
    from .stingers import _write, asset_edit, catalog, load_plan, locale_code, original_preview

    locale = locale_code(args.locale)
    game = resolve_game_dir(args.game_dir)
    current = bool(args.current_game)
    key = catalog_key(project, game, locale, current)
    path = project / "analysis/stingers/cache" / f"{locale}-{int(current)}.json"
    cached = _read(path)
    if (
        cached
        and cached.get("key") == key
        and cached.get("file_signatures") == [_signature(p) for p in cached.get("files", [])]
    ):
        cached["data"]["cache"]["reused"] = True
        return cached["data"]
    data = catalog(project, game, locale, current_game=current)
    plan = load_plan(project)
    total = sum(len(s["slots"]) for s in data["stations"]) + len(data["assets"])
    done = 0
    files = set()
    warnings = []

    def prepare_preview(owner, edit, label):
        try:
            owner["preview"] = edited_preview(args, project, plan, edit)
            files.add(owner["preview"]["path"])
        except CliError as error:
            # A rejected edit must remain accessible so its gain/range can be fixed.
            # Building still validates and rejects the same invalid audio.
            owner.pop("preview", None)
            owner["preview_error"] = str(error)
            warnings.append(f"{label}：{error}")

    def progress():
        if getattr(args, "progress_jsonl", False):
            print(
                "FH_STINGER_CACHE_PROGRESS " + json.dumps({"done": done, "total": total}),
                flush=True,
            )

    progress()
    for station in data["stations"]:
        for slot in station["slots"]:
            slot["original_preview"] = original_preview(args, project, station, slot)
            files.add(slot["original_preview"]["path"])
            if not current and slot.get("assignment"):
                prepare_preview(
                    slot, slot["assignment"], f"R{station['radio']} · 台呼 {slot['number']}"
                )
            done += 1
            progress()
    for asset in data["assets"]:
        asset["edit"] = asset_edit(asset)
        asset["source_preview"] = asset_source(args, project, asset)
        files.add(asset["source_preview"]["path"])
        prepare_preview(asset, asset["edit"], asset.get("name", asset["id"]))
        done += 1
        progress()
    if not current:
        game_data = catalog(project, game, locale, current_game=True)
        for station in game_data["stations"]:
            for slot in station["slots"]:
                slot["original_preview"] = original_preview(args, project, station, slot)
                files.add(slot["original_preview"]["path"])
        # Game view is read-only and needs no duplicate asset waveform payloads.
        game_data["assets"] = []
        data["game_view"] = game_data
    data["cache"] = {
        "reused": False,
        "files": len(files),
        "bytes": sum(Path(p).stat().st_size for p in files),
    }
    if warnings:
        data["preview_warnings"] = warnings
        # Do not pin transient rendering failures into the reusable full cache.
        return data
    ordered = sorted(files)
    _write(
        path,
        {
            "key": key,
            "files": ordered,
            "file_signatures": [_signature(p) for p in ordered],
            "data": data,
        },
    )
    return data
