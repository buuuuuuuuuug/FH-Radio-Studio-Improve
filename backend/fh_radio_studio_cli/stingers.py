"""Project-owned stinger drafts, audition copies, and package composition.

No command here writes into the game directory. The ordinary package deployment
command remains the only game-writing entry point.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import os
import shutil
import subprocess
import tempfile
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path

import numpy as np
import soundfile as sf

from .common import CliError
from .deployment_paths import effective_game_file
from .external_tools import find_executable
from .game import game_root_for, resolve_game_dir
from .metadata import read_track_metadata
from .project_refs import project_path_or_absolute, resolve_project_ref
from .stinger_bank import bank_samples, cue_points, replace_samples, sound_hash

LOCALES = {"BR", "CN", "DE", "EN", "ES", "IT", "JP", "KO", "MX", "TW"}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def plan_path(project: Path) -> Path:
    return project / ".fh-radio-studio" / "stingers.json"


def _write(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("w", encoding="utf-8", newline="\n") as stream:
            json.dump(data, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def load_plan(project: Path) -> dict:
    path = plan_path(project)
    if not path.is_file():
        return {"schema_version": 1, "assets": [], "assignments": {}, "baselines": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, OSError) as error:
        raise CliError("台呼草稿无法读取，原文件已保留") from error
    if (
        data.get("schema_version") != 1
        or not isinstance(data.get("assets"), list)
        or not isinstance(data.get("assignments"), dict)
        or not isinstance(data.get("baselines"), dict)
    ):
        raise CliError("台呼草稿版本或内容无效")
    return data


def local_file(project: Path, reference: str) -> Path:
    if not isinstance(reference, str) or not reference.startswith("fh-project:/"):
        raise CliError("台呼素材必须使用工程内引用")
    path = resolve_project_ref(project, reference)
    if not path.is_file() or project.resolve() not in path.resolve().parents:
        raise CliError("台呼素材或快照不存在，请重新导入")
    return path


def locale_code(value: str) -> str:
    value = {"CHS": "CN", "CHT": "TW", "JA": "JP"}.get(value.upper(), value.upper())
    if value not in LOCALES:
        raise CliError("此语音语言尚未支持台呼编辑")
    return value


def _tool(args, name: str) -> str:
    value = find_executable(getattr(args, name.replace("-", "_"), None), name)
    if not value:
        raise CliError(f"缺少音频工具 {name}，请先修复工具链")
    return value


def _run(command) -> str:
    completed = subprocess.run([str(x) for x in command], capture_output=True)
    if completed.returncode:
        details = (completed.stderr or completed.stdout).decode("utf-8", errors="replace")[-1800:]
        if not details.strip():
            details = f"{Path(str(command[0])).name} 退出码 {completed.returncode}"
        raise CliError(f"音频处理失败：{details}")
    return completed.stdout.decode("utf-8", errors="replace")


def _copy_snapshot(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if digest(source) != digest(destination):
            raise CliError("台呼快照名称冲突，未覆盖已有文件")
        return
    temporary = destination.with_name(destination.name + f".{uuid.uuid4().hex}.tmp")
    try:
        shutil.copyfile(source, temporary)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def _read_catalog(
    project: Path, game_dir: Path, locale: str, *, current_game=False, plan_override=None
) -> dict:
    locale = locale_code(locale)
    plan = plan_override if plan_override is not None else load_plan(project)
    game = game_root_for(game_dir)
    xml = effective_game_file(game, f"media/audio/RadioInfo_{locale}.xml")
    if not xml.is_file():
        raise CliError(f"未找到 {locale} 的 RadioInfo")
    live_tree = ET.parse(xml).getroot()
    stations = []
    for live_station in live_tree.iter("RadioStation"):
        number = int(live_station.get("Number", "0"))
        group = live_station.find("SampleList[@Type='Stinger']")
        if group is None or not group.findall("Sample"):
            continue
        key = f"R{number}:{locale}"
        baseline = plan["baselines"].get(key)
        bank_name = f"R{number}_Stingers_{locale}.assets.bank"
        source = effective_game_file(game, f"media/audio/FMODBanks/{bank_name}")
        source_xml = xml
        station = live_station
        if baseline and not current_game:
            source = local_file(project, baseline["bank_ref"])
            source_xml = local_file(project, baseline["xml_ref"])
            if digest(source_xml) != baseline["xml_sha256"]:
                raise CliError("工程内台呼配置快照已改变")
            pinned = ET.parse(source_xml).getroot()
            station = next(s for s in pinned.iter("RadioStation") if s.get("Number") == str(number))
            group = station.find("SampleList[@Type='Stinger']")
            bank_name = baseline["bank_name"]
        raw = source.read_bytes()
        sha = hashlib.sha256(raw).hexdigest()
        if baseline and not current_game and sha != baseline["sha256"]:
            raise CliError("工程内台呼快照已改变，不能继续构建")
        info, records, _, lookup = bank_samples(raw)
        slots = []
        original_samples = group.findall("Sample")
        samples = original_samples
        for order, sample in enumerate(samples, 1):
            sound = sample.get("SoundName", "")
            index = lookup.get(sound_hash(sound))
            if index is None:
                raise CliError(f"R{number} 台呼名称映射缺失")
            actual = info.samples[index]
            points = cue_points(records[index][1].get(4, b""))
            xml_points = {m.get("Name"): int(m.get("Position")) for m in sample.findall("Marker")}
            if (
                actual.sample_count != int(sample.get("SampleLength", "0"))
                or any(points.get(k) != v for k, v in xml_points.items())
                or not 0 <= points.get("StartNextTrack", -1) < actual.sample_count
            ):
                raise CliError(f"R{number} 台呼 {order} 的配置与音频包不一致")
            slot_id = f"{key}:{sound}"
            slots.append(
                {
                    "id": slot_id,
                    "number": order,
                    "sound_name": sound,
                    "index": index,
                    "duration": actual.sample_count / 48000,
                    "samples": actual.sample_count,
                    "next_track": points["StartNextTrack"] / 48000,
                    "assignment": plan["assignments"].get(slot_id),
                }
            )
        stations.append(
            {
                "radio": number,
                "name": station.get("Name"),
                "key": key,
                "bank_name": bank_name,
                "bank_sha256": sha,
                "bank_path": str(source),
                "xml_path": str(source_xml),
                "slots": slots,
                "original_count": len(original_samples),
            }
        )
    available = sorted(
        {
            p.name.split("_")[2].split(".")[0]
            for p in (game / "media/audio/FMODBanks").glob("R1_Stingers_*.assets.bank")
            if p.name.split("_")[2].split(".")[0] in LOCALES and p.stat().st_size > 1024
        }
    )
    songs = []
    for folder in (project / "sources", project / "siren"):
        for path in sorted(folder.rglob("*")) if folder.is_dir() else []:
            if any(
                path.is_relative_to(project / "sources" / folder)
                for folder in ("stingers", "voices")
            ):
                continue
            if path.is_file() and path.suffix.lower() in {
                ".wav",
                ".mp3",
                ".flac",
                ".ogg",
                ".m4a",
                ".aac",
                ".aiff",
            }:
                songs.append({"path": str(path), "name": path.stem})
    return {
        "locale": locale,
        "available_locales": available,
        "songs": songs,
        "stations": stations,
        "assets": plan["assets"],
        "assignment_count": sum(1 for k in plan["assignments"] if f":{locale}:" in k),
        "plan_sha256": hashlib.sha256(json.dumps(plan, sort_keys=True).encode()).hexdigest(),
        "draft": {
            "assignments": plan["assignments"],
            "asset_edits": {a["id"]: a.get("edit") for a in plan["assets"]},
            "asset_names": {a["id"]: a.get("name", "") for a in plan["assets"]},
        },
    }


def catalog(project: Path, game_dir: Path, locale: str, *, current_game=False) -> dict:
    from .stinger_cache import cached_catalog

    return cached_catalog(project, game_dir, locale, current_game=current_game)


def asset_edit(asset: dict) -> dict:
    duration = float(asset["duration"])
    return {
        "asset_id": asset["id"],
        "start": 0.0,
        "end": duration,
        "gain_db": 0.0,
        "next_track": max(0.0, duration - min(1.2, duration / 4)),
        **(asset.get("edit") or {}),
    }


def _selected(data: dict, slot_id: str):
    for station in data["stations"]:
        for slot in station["slots"]:
            if slot["id"] == slot_id:
                return station, slot
    raise CliError("台呼位置不存在，请重新读取页面")


def _asset(plan, asset_id):
    asset = next((a for a in plan["assets"] if a["id"] == asset_id), None)
    if asset is None:
        raise CliError("台呼素材已移除，请重新选择")
    return asset


def import_audio(project: Path, paths: list[str]) -> dict:
    plan = load_plan(project)
    imported = []
    for value in paths:
        source = Path(value).expanduser().resolve()
        metadata = read_track_metadata(source)
        # UI metadata rounds seconds; sample counts preserve the real clip end.
        duration = (
            metadata.samples / metadata.sample_rate
            if metadata.samples and metadata.sample_rate
            else float(metadata.duration_sec or 0)
        )
        if not math.isfinite(duration) or duration < 0.05:
            raise CliError(f"音频时长无效或不足 0.05 秒：{source.name}")
        sha = digest(source)
        imported.append(sha)
        if any(a["id"] == sha for a in plan["assets"]):
            continue
        target = project / "sources" / "stingers" / (sha + source.suffix.lower())
        _copy_snapshot(source, target)
        plan["assets"].append(
            {
                "id": sha,
                "name": source.stem,
                "source": project_path_or_absolute(project, target),
                "duration": duration,
                "sha256": sha,
            }
        )
    _write(plan_path(project), plan)
    return {"assets": plan["assets"], "asset_ids": imported}


def validate_edit(plan, slot, edit):
    asset = _asset(plan, edit.get("asset_id"))
    try:
        values = {name: float(edit[name]) for name in ("start", "end", "gain_db", "next_track")}
    except (TypeError, ValueError, KeyError) as error:
        raise CliError("台呼裁剪、音量和衔接位置必须是有效数字") from error
    if not all(math.isfinite(v) for v in values.values()):
        raise CliError("台呼设置不能包含无效数字")
    start, end, gain, next_track = (values[k] for k in ("start", "end", "gain_db", "next_track"))
    # Time fields display milliseconds, while assets may end between two ticks.
    # Accept the displayed final millisecond, but render only real samples.
    if float(asset["duration"]) < end <= float(asset["duration"]) + 0.002:
        end = values["end"] = float(asset["duration"])
    if not 0 <= start < end <= float(asset["duration"]) + 0.002 or end - start < 0.05:
        raise CliError("裁剪范围需在素材内，成品台呼时长至少为 0.05 秒")
    if not -6 <= gain <= 6:
        raise CliError("台呼音量调整需在 -6 至 +6 dB")
    from .material_edit import validate_operations

    operations, duration = validate_operations(edit.get("audio_edits", []), end - start)
    samples = round(duration * 48000)
    next_sample = round(next_track * 48000)
    if not 0 <= next_sample < samples:
        raise CliError("下一首开始位置必须位于裁剪后的台呼内")
    return (
        {
            "asset_id": asset["id"],
            **values,
            **({"audio_edits": operations} if "audio_edits" in edit else {}),
        },
        samples,
        next_sample,
    )


def update_assignment(project, game, locale, edit):
    return apply_changes(project, game, locale, {edit.get("slot_id"): edit})


def _pin_baseline(project, plan, station, locale):
    if station["key"] in plan["baselines"]:
        return
    bank = Path(station["bank_path"])
    xml = Path(station["xml_path"])
    folder = project / ".fh-radio-studio/stingers/baselines"
    pinned_bank = folder / (station["bank_sha256"] + ".assets.bank")
    pinned_xml = folder / (digest(xml) + ".xml")
    _copy_snapshot(bank, pinned_bank)
    _copy_snapshot(xml, pinned_xml)
    plan["baselines"][station["key"]] = {
        "radio": station["radio"],
        "locale": locale,
        "bank_name": station["bank_name"],
        "sha256": station["bank_sha256"],
        "bank_ref": project_path_or_absolute(project, pinned_bank),
        "xml_ref": project_path_or_absolute(project, pinned_xml),
        "xml_sha256": digest(pinned_xml),
    }


def apply_changes(project, game, locale, changes):
    plan = load_plan(project)
    data = catalog(project, game, locale)
    checked = []
    if not isinstance(changes, dict):
        raise CliError("台呼批量分配格式无效")
    for slot_id, edit in changes.items():
        station, slot = _selected(data, slot_id)
        values = None
        if edit is not None and not isinstance(edit, dict):
            raise CliError("台呼分配内容格式无效")
        if edit and edit.get("asset_id") is not None:
            values, _, _ = validate_edit(plan, slot, edit)
        checked.append((station, slot, values))
    for station, slot, values in checked:
        if values is None:
            plan["assignments"].pop(slot["id"], None)
        else:
            _pin_baseline(project, plan, station, data["locale"])
            plan["assignments"][slot["id"]] = values
    _write(plan_path(project), plan)
    return {"saved": True, "assignment_count": len(plan["assignments"])}


def update_asset(project, asset_id, edit):
    plan = load_plan(project)
    asset = _asset(plan, asset_id)
    values, _, _ = validate_edit(plan, {}, {**edit, "asset_id": asset_id})
    asset["edit"] = values
    if "name" in edit:
        name = str(edit["name"]).strip()
        if not name or len(name) > 200:
            raise CliError("素材名称需为 1–200 个字符")
        asset["name"] = name
    count = 0
    for key, current in plan["assignments"].items():
        if current.get("asset_id") == asset_id:
            plan["assignments"][key] = dict(values)
            count += 1
    _write(plan_path(project), plan)
    return {"saved": True, "updated_assignments": count}


def restore_draft(project, game, locale, draft):
    plan = load_plan(project)
    assignments = draft.get("assignments")
    edits = draft.get("asset_edits", {})
    if not isinstance(assignments, dict) or not isinstance(edits, dict):
        raise CliError("台呼历史记录格式无效")
    # Older editors represented a clear as an all-null edit. It is a removal,
    # never an assignment to a missing asset.
    assignments = {
        key: value
        for key, value in assignments.items()
        if not (
            isinstance(value, dict)
            and value.get("asset_id") is None
            and all(value.get(k) is None for k in ("start", "end", "gain_db", "next_track"))
        )
    }
    all_locales = draft.get("all_locales") is True
    locales = {locale_code(locale)}
    if all_locales:
        # A locale with its last assignment cleared is absent from the incoming
        # map, but is still part of the complete draft being saved.
        for key in set(assignments) | set(plan["assignments"]):
            parts = key.split(":")
            if len(parts) < 2 or parts[1] not in LOCALES:
                raise CliError("台呼分配包含无效语言")
            locales.add(parts[1])
    for language in sorted(locales):
        data = catalog(project, game, language)
        known = {slot["id"] for station in data["stations"] for slot in station["slots"]}
        active = {key: value for key, value in assignments.items() if f":{language}:" in key}
        if not set(active).issubset(known):
            raise CliError("草稿含有不存在的台呼位置")
        locations = {
            s["id"]: f"R{station['radio']} · 台呼 {s['number']}（{language}）"
            for station in data["stations"]
            for s in station["slots"]
        }
        for slot_id, value in active.items():
            label = locations[slot_id]
            try:
                if not isinstance(value, dict):
                    raise CliError("该位置的替换设置无效")
                validate_edit(plan, {}, value)
                asset = _asset(plan, value["asset_id"])
                local_file(project, asset["source"])
            except (CliError, TypeError, KeyError) as error:
                name = (
                    draft.get("asset_names", {}).get(value.get("asset_id"))
                    if isinstance(value, dict)
                    else None
                )
                raise CliError(
                    f"{label}：{error}"
                    + (f"（素材：{name}）" if name else "")
                    + "。请重新选择素材，或清除此位置的替换后再保存。"
                ) from error
        for station in data["stations"]:
            if any(s["id"] in active for s in station["slots"]):
                _pin_baseline(project, plan, station, language)
    removed = set(draft.get("removed_assets", []))
    known_assets = {a["id"] for a in plan["assets"]}
    merged = {k: v for k, v in plan["assignments"].items() if k.split(":")[1] not in locales}
    merged.update({k: v for k, v in assignments.items() if k.split(":")[1] in locales})
    if any(value.get("asset_id") in removed for value in merged.values()):
        raise CliError("待移除素材仍被台呼使用")
    for asset_id, edit in edits.items():
        if asset_id in removed or asset_id not in known_assets:
            continue
        asset = _asset(plan, asset_id)
        if edit is not None:
            values, _, _ = validate_edit(plan, {}, edit)
            asset["edit"] = values
        else:
            asset.pop("edit", None)
    for asset_id, name in draft.get("asset_names", {}).items():
        if asset_id in removed or asset_id not in known_assets:
            continue
        if not isinstance(name, str) or not name.strip() or len(name) > 200:
            raise CliError("历史记录中的素材名称无效")
        _asset(plan, asset_id)["name"] = name
    plan["assignments"] = merged
    plan["assets"] = [a for a in plan["assets"] if a["id"] not in removed]
    _write(plan_path(project), plan)
    return {"saved": True}


def _wave(path):
    from .stinger_cache import cached_wave

    return cached_wave(path)


def _read_wave(path):
    values, rate = sf.read(path, dtype="float32", always_2d=True)
    count = min(4096, len(values))
    mono = np.max(np.abs(values), axis=1)
    bins = [float(np.max(v)) for v in np.array_split(mono, count)] if count else []
    return {"path": str(path), "duration": len(values) / rate, "bins": bins}


def original_preview(args, project, station, slot):
    from .stinger_cache import valid_pcm

    target = (
        project
        / "analysis"
        / "stingers"
        / "originals"
        / f"{station['bank_sha256']}-{slot['index']}.wav"
    )
    if not valid_pcm(target, slot["samples"]):
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_name(target.stem + f".{uuid.uuid4().hex}.wav")
        try:
            _run(
                [
                    _tool(args, "vgmstream-cli"),
                    "-s",
                    slot["index"] + 1,
                    "-i",
                    "-o",
                    temporary,
                    station["bank_path"],
                ]
            )
            with sf.SoundFile(temporary) as audio:
                if (
                    len(audio) != slot["samples"]
                    or audio.samplerate != 48000
                    or audio.channels != 2
                ):
                    raise CliError("原台呼解码结果与配置不一致")
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)
    return {**_wave(target), "next_track": slot["next_track"]}


def render(args, project, plan, slot, edit, output):
    values, samples, next_sample = validate_edit(plan, slot, edit)
    asset = _asset(plan, values["asset_id"])
    source = local_file(project, asset["source"])
    if digest(source) != asset["sha256"]:
        raise CliError("工程内台呼素材已改变，请重新导入")
    output.parent.mkdir(parents=True, exist_ok=True)
    floating = output.with_name(output.stem + ".float.wav")
    seek_start = values["start"]
    if values.get("audio_edits"):
        from .material_edit import material_wave

        material = material_wave(args, project, asset, values, namespace="stingers")
        source, seek_start = Path(material["path"]), 0
    duration = samples / 48000
    filters = (
        f"aresample=48000,atrim=end_sample={samples},asetpts=PTS-STARTPTS,"
        f"volume={values['gain_db'] + float(getattr(args, '_stinger_render_gain_db', 0))}dB,afade=t=in:st=0:d={min(.008, duration / 4)},"
        f"afade=t=out:st={max(0, duration-.015)}:d={min(.015, duration / 4)}"
    )
    try:
        _run(
            [
                _tool(args, "ffmpeg"),
                "-hide_banner",
                "-loglevel",
                "error",
                "-nostdin",
                "-y",
                "-ss",
                seek_start,
                "-i",
                source,
                "-t",
                duration,
                "-ac",
                2,
                "-ar",
                48000,
                "-af",
                filters,
                "-c:a",
                "pcm_f32le",
                floating,
            ]
        )
        pcm, rate = sf.read(floating, dtype="float32", always_2d=True)
        if len(pcm) != samples or rate != 48000 or pcm.shape[1] != 2:
            raise CliError("处理后台呼的采样长度不一致，请稍微缩短裁剪终点")
        peak = float(np.max(np.abs(pcm)))
        if not math.isfinite(peak) or peak > 1.00001:
            raise CliError("台呼音量过高，可能削波；请降低音量后重试")
        sf.write(output, pcm, rate, subtype="PCM_16")
    finally:
        floating.unlink(missing_ok=True)
    return samples, next_sample


def cmd_stingers(args):
    if args.action == "serve":
        from .stinger_worker import serve

        return serve(args)
    from .file_lock import exclusive_file_lock

    mutations = {
        "organize",
        "import",
        "update",
        "update-asset",
        "remove-asset",
        "set-assignments",
        "restore-draft",
        "copy-game",
        "copy-game-draft",
    }
    if args.action not in mutations:
        return _cmd_stingers(args)
    lock = Path(args.project_dir) / ".fh-radio-studio/stingers.lock"
    with exclusive_file_lock(lock, timeout_sec=10):
        return _cmd_stingers(args)


def _cmd_stingers(args):
    project = Path(args.project_dir).expanduser().resolve()
    if not (project / ".fh-radio-studio" / "project.json").is_file():
        raise CliError("请先新建或打开独立工程")
    if args.action == "organize":
        from .stinger_storage import organize_sources

        result = organize_sources(project)
    elif args.action == "warm-cache":
        from .stinger_cache import warm_cache

        result = warm_cache(args, project)
    elif args.action in {"copy-game", "copy-game-draft"}:
        from .stinger_game_copy import copy_game

        result = copy_game(
            args,
            project,
            resolve_game_dir(args.game_dir),
            locale_code(args.locale),
            draft_only=args.action == "copy-game-draft",
        )
    elif args.action == "import":
        result = import_audio(project, args.paths)
    elif args.action in {"update-asset", "asset-preview"}:
        import sys

        edit = json.load(sys.stdin)
        if args.action == "update-asset":
            result = update_asset(project, args.asset_id, edit)
        else:
            from .stinger_cache import edited_preview

            plan = load_plan(project)
            if edit.get("material_wave"):
                from .material_edit import material_wave

                result = material_wave(
                    args, project, _asset(plan, args.asset_id), edit, namespace="stingers"
                )
            else:
                result = edited_preview(args, project, plan, {**edit, "asset_id": args.asset_id})
    elif args.action in {"set-assignments", "restore-draft"}:
        import sys

        edit = json.load(sys.stdin)
        game = resolve_game_dir(args.game_dir)
        result = (
            apply_changes(project, game, args.locale, edit["changes"])
            if args.action == "set-assignments"
            else restore_draft(project, game, args.locale, edit)
        )
    elif args.action == "asset":
        asset = _asset(load_plan(project), args.asset_id)
        source = local_file(project, asset["source"])
        if digest(source) != asset["sha256"]:
            raise CliError("台呼素材已改变，请重新导入")
        result = {"path": str(source), "duration": asset["duration"]}
    else:
        game = resolve_game_dir(args.game_dir)
        data = catalog(project, game, args.locale, current_game=args.current_game)
        if args.action == "catalog":
            result = data
        elif args.action == "update":
            import sys

            result = update_assignment(project, game, args.locale, json.load(sys.stdin))
        elif args.action == "remove-asset":
            plan = load_plan(project)
            if any(v.get("asset_id") == args.asset_id for v in plan["assignments"].values()):
                raise CliError("素材仍被台呼使用，请先清除对应分配")
            plan["assets"] = [a for a in plan["assets"] if a["id"] != args.asset_id]
            _write(plan_path(project), plan)
            result = {"removed": True}
        else:
            station, slot = _selected(data, args.slot)
            if args.action == "original":
                result = original_preview(args, project, station, slot)
            else:
                import sys

                edit = json.load(sys.stdin)
                key = hashlib.sha256(json.dumps(edit, sort_keys=True).encode()).hexdigest()
                output = project / "analysis" / "stingers" / "previews" / f"{key}.wav"
                if args.action == "seam" and edit.get("original"):
                    original = original_preview(args, project, station, slot)
                    result = original
                    output = Path(original["path"])
                    next_sample = round(slot["next_track"] * 48000)
                else:
                    from .stinger_cache import edited_preview

                    result = edited_preview(args, project, load_plan(project), edit)
                    output = Path(result["path"])
                    next_sample = round(result["next_track"] * 48000)
                result = {**result, **_wave(output), "next_track": next_sample / 48000}
                if args.action == "seam":
                    choices = {entry["path"] for entry in data["songs"]}
                    before, after = str(edit.get("before")), str(edit.get("after"))
                    if before not in choices or after not in choices:
                        raise CliError("衔接预览请选择当前工程中的歌曲")
                    from .stinger_cache import valid_pcm

                    signatures = [
                        (p, Path(p).stat().st_size, Path(p).stat().st_mtime_ns)
                        for p in (before, after, str(output))
                    ]
                    seam_key = hashlib.sha256(
                        json.dumps([edit, signatures], sort_keys=True).encode()
                    ).hexdigest()
                    mixed = project / "analysis/stingers/previews" / f"{seam_key}.seam.wav"
                    mixed.parent.mkdir(parents=True, exist_ok=True)
                    before_sec = float(edit.get("before_seconds", 6))
                    after_sec = float(edit.get("after_seconds", 4))
                    if (
                        not math.isfinite(before_sec)
                        or not 0 <= before_sec <= 30
                        or not math.isfinite(after_sec)
                        or not 0 <= after_sec <= 60
                    ):
                        raise CliError("衔接试听时长无效：前音乐 0–30 秒，下一首 0–60 秒")
                    fade = min(0.6, before_sec)
                    stinger_start = max(0.0, before_sec - fade)
                    voice_delay = round(stinger_start * 1000)
                    delay = round(stinger_start * 1000 + next_sample / 48)
                    filters = (
                        f"[0:a]aresample=48000,aformat=channel_layouts=stereo,atrim=duration={max(.001,before_sec)},"
                        f"asetpts=PTS-STARTPTS,volume={.35 if before_sec else 0},afade=t=out:st={stinger_start}:d={max(.001,fade)}[before];"
                        f"[1:a]aresample=48000,aformat=channel_layouts=stereo,asetpts=PTS-STARTPTS,adelay={voice_delay}|{voice_delay}[stinger];"
                        f"[2:a]aresample=48000,aformat=channel_layouts=stereo,atrim=duration={max(.001,after_sec)},"
                        f"asetpts=PTS-STARTPTS,volume={.6 if after_sec else 0},afade=t=in:st=0:d={min(.5,max(.001,after_sec))},adelay={delay}|{delay}[after];"
                        "[before][stinger][after]amix=inputs=3:duration=longest:normalize=0,alimiter=limit=0.95[out]"
                    )
                    if not valid_pcm(mixed):
                        _run(
                            [
                                _tool(args, "ffmpeg"),
                                "-hide_banner",
                                "-loglevel",
                                "error",
                                "-nostdin",
                                "-y",
                                "-sseof",
                                str(-max(0.001, before_sec)),
                                "-i",
                                before,
                                "-i",
                                output,
                                "-i",
                                after,
                                "-filter_complex",
                                filters,
                                "-map",
                                "[out]",
                                "-c:a",
                                "pcm_s16le",
                                mixed,
                            ]
                        )
                    result = {
                        **_wave(mixed),
                        "next_track": stinger_start + next_sample / 48000,
                        "kind": "seam",
                        "stinger_start": stinger_start,
                        "before_seconds": before_sec,
                        "after_seconds": after_sec,
                    }
    print(json.dumps(result, ensure_ascii=False, allow_nan=False))
    return 0


def freeze_for_build(args):
    """Freeze project edits before music encoding starts, including removals."""
    value = getattr(args, "stinger_project", None)
    if not value:
        return None
    project = Path(value).expanduser().resolve()
    plan = load_plan(project)
    if not plan["baselines"]:
        return None
    gain = float(getattr(args, "stinger_gain_db", 0))
    if not math.isfinite(gain) or not -6 <= gain <= 6:
        raise CliError("台呼统一增益需在 -6 至 +6 dB")
    known_slots, labels = set(), {}
    for baseline in plan["baselines"].values():
        for field, checksum in (("bank_ref", "sha256"), ("xml_ref", "xml_sha256")):
            if digest(local_file(project, baseline[field])) != baseline[checksum]:
                raise CliError("台呼原始快照校验失败，已保留旧准备包")
        root = ET.parse(local_file(project, baseline["xml_ref"])).getroot()
        station = next(
            s for s in root.iter("RadioStation") if s.get("Number") == str(baseline["radio"])
        )
        for number, sample in enumerate(
            station.find("SampleList[@Type='Stinger']").findall("Sample"), 1
        ):
            slot_id = f"R{baseline['radio']}:{baseline['locale']}:{sample.get('SoundName')}"
            known_slots.add(slot_id)
            labels[slot_id] = f"R{baseline['radio']} · 台呼 {number}（{baseline['locale']}）"
    if not set(plan["assignments"]).issubset(known_slots):
        raise CliError("台呼草稿包含未关联位置，已保留旧准备包")
    for slot_id, edit in plan["assignments"].items():
        try:
            validate_edit(plan, {}, edit)
            asset = _asset(plan, edit["asset_id"])
            if digest(local_file(project, asset["source"])) != asset["sha256"]:
                raise CliError(f"素材「{asset.get('name', '未命名音频')}」已改变，请重新导入")
        except (CliError, TypeError, KeyError) as error:
            raise CliError(
                f"{labels[slot_id]}：{error}。请重新选择素材或清除替换；旧准备包已保留。"
            ) from error
    return {
        "project": str(project),
        "plan": plan,
        "sha256": hashlib.sha256(json.dumps(plan, sort_keys=True).encode()).hexdigest(),
        "gain_db": gain,
    }


def build_base_package(args, audio_dir):
    """A stinger-only edit preserves the last prepared songs and their XML."""
    from .package import package_file_fingerprints, package_language_settings

    root = Path(args.out_dir) / "package"
    previous = (
        Path(args.reuse_package) / "package" if getattr(args, "reuse_package", None) else None
    )
    manifest = None
    if (
        previous
        and not getattr(args, "playlist_plan", None)
        and (previous / "fh_radio_studio_package_manifest.json").is_file()
    ):
        old = json.loads(
            (previous / "fh_radio_studio_package_manifest.json").read_text(encoding="utf-8")
        )
        # A reusable package must still be exactly the completed package.
        actual = package_file_fingerprints(previous)
        fields = ("relative_path", "install_relative_path", "size", "md5")
        signature = lambda items: sorted(tuple(item.get(key) for key in fields) for item in items)
        if signature(actual) != signature(old.get("package_files") or []):
            raise CliError("上次准备包文件已改变，不能与台呼合并")
        shutil.copytree(previous, root, dirs_exist_ok=True)
        manifest = old
    root.mkdir(parents=True, exist_ok=True)
    destination = root / "media" / "audio"
    destination.mkdir(parents=True, exist_ok=True)
    if manifest is None:
        for xml in Path(audio_dir).glob("RadioInfo_*.xml"):
            shutil.copyfile(xml, destination / xml.name)
        manifest = {
            "schema_version": 2,
            "game": "FH6",
            "radios": [],
            "radio": None,
            "station": "电台台呼",
            "bank_slots": 0,
            "assignments": [],
            "quality": args.quality,
            "playlist_mode": "preserve",
            "runtime_verified": False,
        }
    if args.source or args.target:
        language = package_language_settings(
            args,
            resolve_game_dir(args.game_dir),
            root / "media" / "Stripped" / "StringTables",
        )
        if language:
            manifest["language"] = language
    _write(root / "fh_radio_studio_package_manifest.json", manifest)
    print("已保留歌曲与播放列表，准备合并台呼修改。")
    return 0


def _verify_audio(args, bank, slots, rendered, folder):
    """Decode every final slot; compare changed audio to its assigned source."""
    for slot in slots:
        decoded = folder / f"verify-{slot['index']:03d}.wav"
        _run(
            [
                _tool(args, "vgmstream-cli"),
                "-s",
                slot["index"] + 1,
                "-i",
                "-o",
                decoded,
                bank,
            ]
        )
        pcm, rate = sf.read(decoded, dtype="float32", always_2d=True)
        expected_file = rendered.get(slot["sound_name"])
        expected_frames = slot["samples"]
        if expected_file:
            expected, _ = sf.read(expected_file, dtype="float32", always_2d=True)
            expected_frames = len(expected)
            # Vorbis is lossy. Compare the decoded signal, not WAV file bytes.
            count = min(len(expected), len(pcm))
            a, b = expected[:count].reshape(-1).astype("float64"), pcm[:count].reshape(-1).astype(
                "float64"
            )
            denominator = float(np.linalg.norm(a) * np.linalg.norm(b))
            similarity = float(np.dot(a, b) / denominator) if denominator > 1e-8 else 1.0
            if similarity < 0.90:
                raise CliError("重构台呼与指定素材不匹配，可能发生错位，已停止构建")
        if rate != 48000 or pcm.shape[1] != 2 or len(pcm) != expected_frames:
            raise CliError("重构台呼的解码长度或声道不一致")
        decoded.unlink()


def _compose_package(args):
    frozen = getattr(args, "_stinger_snapshot", None)
    if frozen is None:
        return
    if getattr(args, "skip_bank", False):
        raise CliError("包含台呼修改的准备包不能跳过音频包重构")
    project = Path(frozen["project"])
    plan = frozen["plan"]
    package = Path(args.out_dir) / "package"
    manifest_file = package / "fh_radio_studio_package_manifest.json"
    manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
    work = Path(args.out_dir) / "work" / "stingers"
    work.mkdir(parents=True, exist_ok=True)
    banks, patches = [], {}
    processed_assignments = set()
    gain = float(frozen.get("gain_db", 0))
    args._stinger_render_gain_db = gain
    # A reused package may contain edits and added XML entries from an older
    # build. Restore only the stinger lists before applying the current draft;
    # song lists/metadata in the same RadioInfo remain untouched.
    for xml in (package / "media/audio").glob("RadioInfo_*.xml"):
        source = Path(getattr(args, "source_audio_dir", None) or "") / xml.name
        if not source.is_file():
            source = next(
                (
                    local_file(project, b["xml_ref"])
                    for b in plan["baselines"].values()
                    if local_file(project, b["xml_ref"]).name == xml.name
                ),
                None,
            )
            if source is None:
                source = next(
                    (
                        local_file(project, b["xml_ref"])
                        for b in plan["baselines"].values()
                        if xml.stem.endswith("_" + b["locale"])
                    ),
                    None,
                )
        if source is None or not source.is_file():
            continue
        tree, pristine = ET.parse(xml), ET.parse(source)
        for station in tree.getroot().iter("RadioStation"):
            if not any(
                str(b["radio"]) == station.get("Number") for b in plan["baselines"].values()
            ):
                continue
            original = next(
                (
                    s
                    for s in pristine.getroot().iter("RadioStation")
                    if s.get("Number") == station.get("Number")
                ),
                None,
            )
            group = station.find("SampleList[@Type='Stinger']")
            saved_group = (
                original.find("SampleList[@Type='Stinger']") if original is not None else None
            )
            if group is not None and saved_group is not None:
                index = list(station).index(group)
                station.remove(group)
                station.insert(index, copy.deepcopy(saved_group))
        tree.write(xml, encoding="utf-8", xml_declaration=True)
    try:
        for key, baseline in plan["baselines"].items():
            active = any(k.startswith(key + ":") for k in plan["assignments"])
            output = package / "media" / "audio" / "FMODBanks" / baseline["bank_name"]
            if not active:
                # History snapshots are not packaging instructions. A reverted
                # station is only emitted if a custom bank is already in game
                # and needs an explicit restoration write.
                live = None
                if getattr(args, "game_dir", None):
                    live = effective_game_file(
                        game_root_for(Path(args.game_dir)),
                        f"media/audio/FMODBanks/{baseline['bank_name']}",
                    )
                if live is not None and live.is_file() and digest(live) != baseline["sha256"]:
                    output.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(local_file(project, baseline["bank_ref"]), output)
                    banks.append(
                        {
                            "radio": baseline["radio"],
                            "locale": baseline["locale"],
                            "bank": baseline["bank_name"],
                            "replaced": 0,
                            "restored": True,
                            "source_sha256": baseline["sha256"],
                            "sha256": digest(output),
                        }
                    )
                else:
                    output.unlink(missing_ok=True)
                continue
            raw = local_file(project, baseline["bank_ref"]).read_bytes()
            if hashlib.sha256(raw).hexdigest() != baseline["sha256"]:
                raise CliError("构建期间台呼快照已改变")
            source_xml = local_file(project, baseline["xml_ref"])
            station = next(
                s
                for s in ET.parse(source_xml).getroot().iter("RadioStation")
                if s.get("Number") == str(baseline["radio"])
            )
            info, _, _, lookup = bank_samples(raw)
            slots = []
            replacements, rendered = {}, {}
            folder = work / key.replace(":", "-")
            folder.mkdir(parents=True, exist_ok=True)
            original_samples = station.find("SampleList[@Type='Stinger']").findall("Sample")
            for number, sample in enumerate(original_samples):
                name = sample.get("SoundName")
                index = lookup[sound_hash(name)]
                template_index = index
                slot = {
                    "id": f"{key}:{name}",
                    "sound_name": name,
                    "index": index,
                    "samples": info.samples[template_index].sample_count,
                }
                slots.append(slot)
                edit = plan["assignments"].get(slot["id"])
                if edit is None:
                    points = {
                        m.get("Name"): int(m.get("Position")) for m in sample.findall("Marker")
                    }
                    patches[name] = {
                        "samples": slot["samples"],
                        "next": points["StartNextTrack"],
                        "end": points["End"],
                    }
                    continue
                stage = folder / f"slot-{index:03d}"
                wav = stage / "01.wav"
                try:
                    samples, next_sample = render(args, project, plan, slot, edit, wav)
                except CliError as error:
                    asset = _asset(plan, edit["asset_id"])
                    raise CliError(
                        f"R{baseline['radio']} · 台呼 {number + 1}（{baseline['locale']}），素材「{asset.get('name', '未命名音频')}」：{error}"
                    ) from error
                # Encoding a single slot removes any dependency on directory sort order.
                encoded_dir = folder / f"encoded-{index:03d}"
                encoded_dir.mkdir()
                encoder_log = _run(
                    [
                        _tool(args, "fsbankcl"),
                        "-write_peak_volume",
                        "-o",
                        encoded_dir,
                        "-format",
                        "vorbis",
                        "-quality",
                        str(args.quality),
                        "-recursive",
                        stage,
                    ]
                )
                results = list(encoded_dir.rglob("*.fsb"))
                if len(results) != 1:
                    raise CliError("编码器没有生成唯一的单条台呼结果：" + encoder_log[-1400:])
                encoded = results[0].read_bytes()
                from .fsb5 import parse_fsb5_bytes

                parsed = parse_fsb5_bytes(encoded)
                if parsed.num_samples != 1 or parsed.samples[0].sample_count != samples:
                    raise CliError("台呼编码采样长度不一致")
                replacements[name] = (encoded, next_sample)
                processed_assignments.add(slot["id"])
                rendered[name] = wav
                patches[name] = {
                    "samples": samples,
                    "next": next_sample,
                    "end": samples - 1,
                }
            output = package / "media" / "audio" / "FMODBanks" / baseline["bank_name"]
            output.parent.mkdir(parents=True, exist_ok=True)
            result, checks = replace_samples(raw, replacements)
            output.write_bytes(result)
            _verify_audio(args, output, slots, rendered, folder)
            banks.append(
                {
                    "radio": baseline["radio"],
                    "locale": baseline["locale"],
                    "bank": baseline["bank_name"],
                    "source_sha256": baseline["sha256"],
                    "sha256": digest(output),
                    **checks,
                    "decode_verified": True,
                }
            )
            print(
                f"台呼 R{baseline['radio']} {baseline['locale']}：替换 {len(replacements)} 条，其余原音频已校验保留。",
                flush=True,
            )
        if processed_assignments != set(plan["assignments"]):
            raise CliError("台呼草稿包含无效或未关联的位置，旧准备包已保留")
        counts = {name: 0 for name in patches}
        for xml in (package / "media" / "audio").glob("RadioInfo_*.xml"):
            tree = ET.parse(xml)
            changed = False
            locale = xml.stem.split("_")[-1]
            for group in tree.getroot().iter("SampleList"):
                if group.get("Type") != "Stinger":
                    continue
                for sample in group.findall("Sample"):
                    patch = patches.get(sample.get("SoundName"))
                    if patch is None:
                        continue
                    counts[sample.get("SoundName")] += 1
                    sample.set("SampleLength", str(patch["samples"]))
                    sample.set("SampleRate", "48000")
                    for point, value in (
                        ("StartNextTrack", patch["next"]),
                        ("End", patch["end"]),
                    ):
                        marker = sample.find(f"Marker[@Name='{point}']")
                        if marker is None:
                            raise CliError("准备包台呼标记缺失，不能发布不完整配置")
                        marker.set("Position", str(value))
                        if point in sample.attrib:
                            sample.set(point, str(value))
                    changed = True
            if changed:
                ET.indent(tree, space="  ")
                tree.write(xml, encoding="utf-8", xml_declaration=True)
                ET.parse(xml)
        if any(count == 0 for count in counts.values()):
            raise CliError("歌曲与台呼准备包的 RadioInfo 不匹配，旧准备包已保留")
        from .package import package_file_fingerprints

        manifest["stingers"] = {
            "schema_version": 1,
            "plan_sha256": frozen["sha256"],
            "assignment_count": len(plan["assignments"]),
            "gain_db": gain,
            "banks": banks,
            "xml_verified": True,
            "runtime_verified": False,
        }
        manifest["package_files"] = package_file_fingerprints(package)
        _write(manifest_file, manifest)
    finally:
        args._stinger_render_gain_db = 0
        shutil.rmtree(work, ignore_errors=True)


def compose_package(args):
    from .package import _PackageProgressReporter

    progress = _PackageProgressReporter(bool(getattr(args, "progress_jsonl", False)))
    with progress.stage("stinger_banks", summary="台呼音频、索引和共享 RadioInfo 已核对"):
        return _compose_package(args)
