"""Project-owned voice resources, immutable originals and replacement drafts."""

import copy
import hashlib
import json
import math
import shutil
from pathlib import Path

from .common import CliError, md5_file
from .deployment_paths import effective_game_file
from .fsb5 import parse_fsb5_bytes
from .game import game_root_for
from .project_refs import project_path_or_absolute
from .stingers import _copy_snapshot, _run, _tool, _write, digest, local_file
from .voice_bank import read_bank, replace_indices

EXTENSIONS = {".bank", ".fsb", ".wav", ".ogg", ".mp3", ".wem", ".pck"}


def plan_path(project):
    return project / ".fh-radio-studio/voices.json"


def load_plan(project):
    path = plan_path(project)
    if not path.is_file():
        return {"schema_version": 1, "banks": {}, "assets": []}
    try:
        plan = json.loads(path.read_text(encoding="utf-8"))
        if (
            plan.get("schema_version") != 1
            or not isinstance(plan["banks"], dict)
            or not isinstance(plan["assets"], list)
        ):
            raise ValueError()
        return plan
    except (ValueError, KeyError) as error:
        raise CliError("语音替换工程无法读取，原文件已保留。") from error


def category(name):
    value = name.lower()
    if "stinger" in value:
        return "电台台呼"
    if value.startswith("vo_dj_") or "radio" in value and value.startswith("vo_"):
        return "电台 DJ"
    if "satnav" in value or "anna" in value:
        return "导航"
    if any(x in value for x in ("presenter", "announcer", "forzathon", "gameplay")):
        return "活动与播报"
    if value.startswith("vo_"):
        return "角色与其他语音"
    if "tracks" in value or "music" in value:
        return "歌曲与音乐"
    if any(x in value for x in ("car", "engine", "ambient", "sfx")):
        return "车辆与环境"
    return "其他音频"


def scan(project, game, **text_languages):
    files = {}
    capabilities_path = project / "analysis/voices/scan-capabilities.json"
    capabilities = (
        json.loads(capabilities_path.read_text(encoding="utf-8"))
        if capabilities_path.is_file()
        else {}
    )
    # The overlay wins by relative path, exactly as it does for song resources.
    for layer in ("media", "mediapc"):
        folder = game / layer / "audio"
        if not folder.is_dir():
            continue
        for path in sorted(folder.rglob("*")):
            if not path.is_file() or path.is_symlink() or path.suffix.lower() not in EXTENSIONS:
                continue
            relative = (Path("media/audio") / path.relative_to(folder)).as_posix()
            files[relative] = {
                "path": str(path),
                "relative_path": relative,
                "name": path.name,
                "category": category(path.name),
                "size": path.stat().st_size,
                "layer": layer,
            }
    plan = load_plan(project)
    from .voice_workspace import cached_catalogs, probe

    catalogs = cached_catalogs(project, plan, game, **text_languages)
    active = catalogs.get(plan.get("last_selected_bank"))
    by_path = {b["relative_path"]: b for b in plan["banks"].values()}
    for bank in plan["banks"].values():
        if bank.get("custom"):
            files[bank["relative_path"]] = {
                "path": bank.get("import_path", str(local_file(project, bank["source"]))),
                "relative_path": bank["relative_path"],
                "name": bank["name"],
                "category": "自选文件",
                "size": local_file(project, bank["source"]).stat().st_size,
                "custom": True,
            }
    for file in files.values():
        bank = by_path.get(file["relative_path"])
        if bank:
            file.update(
                bank_id=bank["id"],
                prepared=True,
                modified=bool(bank["replacements"]),
                status="可替换" if bank["supported"] else "仅试听" if bank["count"] else "无法解析",
                reason=bank["reason"],
            )
        else:
            path = Path(file["path"])
            signature = f"{path.stat().st_size}:{path.stat().st_mtime_ns}"
            cached = capabilities.get(str(path), {})
            if cached.get("signature") == signature:
                status, reason = cached["status"], cached["reason"]
            else:
                status, reason = probe(path)
                capabilities[str(path)] = dict(signature=signature, status=status, reason=reason)
            file.update(status=status, reason=reason)
        if file["status"] == "无法解析" and not file.get("custom"):
            file["category"] = "无法解析／控制文件"
    package = project / "packages/voices-current/package/fh_radio_studio_package_manifest.json"
    _write(capabilities_path, capabilities)
    package_ready = False
    if package.is_file():
        from .voice_workspace import plan_stamp

        package_ready = json.loads(package.read_text(encoding="utf-8")).get("voices", {}).get(
            "plan_sha256"
        ) == plan_stamp(plan)
    return {
        "files": list(files.values()),
        "plan": plan,
        "active": active,
        "catalogs": catalogs,
        "package_ready": package_ready,
    }


def prepare(project, game, source, args=None, **text_languages):
    source = Path(source).expanduser().resolve()
    if not source.is_file() or source.suffix.lower() not in EXTENSIONS:
        raise CliError("请选择存在的音频资源文件。")
    relative = None
    for layer in ("media", "mediapc"):
        base = (game / layer / "audio").resolve()
        if source.is_relative_to(base):
            relative = (Path("media/audio") / source.relative_to(base)).as_posix()
            break
    relative = relative or f"media/audio/FMODBanks/{source.name}"
    identity = hashlib.sha256(relative.encode()).hexdigest()[:24]
    plan = load_plan(project)
    existing = plan["banks"].get(identity)
    if existing and plan.get("last_selected_bank") != identity:
        plan["last_selected_bank"] = identity
        _write(plan_path(project), plan)
    if existing:
        snapshot = local_file(project, existing["source"])
        if digest(snapshot) != existing["sha256"]:
            raise CliError("原音频备份校验失败，不能继续编辑。")
        cache = project / f"analysis/voices/catalog/{existing['sha256']}.json"
        if cache.is_file():
            from .voice_workspace import cached_catalogs

            refreshed = cached_catalogs(project, plan, game, **text_languages)[identity]
            return {
                "bank": existing,
                "entries": refreshed["entries"],
                "plan": plan,
            }
    if existing:
        # A missing derived catalog does not authorize adopting the current
        # game bank. Replacement indices belong to the pinned original, whose
        # contents were verified above, even after a game update or mod write.
        sha = existing["sha256"]
    else:
        sha = digest(source)
        snapshot = project / ".fh-radio-studio/voices/baselines" / (sha + source.suffix.lower())
        _copy_snapshot(source, snapshot)
    raw = snapshot.read_bytes()
    supported, reason, entries = True, "", []
    try:
        info = parse_fsb5_bytes(raw, max_samples=32768)
        entries = [
            {
                "index": s.index,
                "name": s.name or f"条目 {s.index + 1:05}",
                "duration": s.sample_count / s.frequency,
                "samples": s.sample_count,
                "frequency": s.frequency,
                "channels": s.channels,
            }
            for s in info.samples
        ]
        read_bank(raw)
        if "_Stingers_" in source.name or "_Tracks_" in source.name:
            supported, reason = False, "此资源由歌曲／电台台呼页面管理，请在对应页面编辑。"
        elif Path(relative).parent.as_posix() != "media/audio/FMODBanks":
            supported, reason = False, "可浏览和试听；此目录的资源尚未验证写入重构。"
    except CliError as error:
        supported, reason = False, str(error)
        if source.suffix.lower() in {".wav", ".ogg", ".mp3", ".flac"}:
            from .metadata import read_track_metadata

            meta = read_track_metadata(snapshot)
            if meta.samples and meta.sample_rate:
                entries = [
                    {
                        "index": 0,
                        "name": source.stem,
                        "duration": meta.samples / meta.sample_rate,
                        "samples": meta.samples,
                        "frequency": meta.sample_rate,
                        "channels": meta.channels or 1,
                    }
                ]
                reason = "独立音频可浏览和试听；尚未验证重构写入。"
    from .voice_text import TEXT_VERSION, attach_dialogue

    bank = {
        "id": identity,
        "name": source.name,
        "relative_path": relative,
        "source": project_path_or_absolute(project, snapshot),
        "sha256": sha,
        "category": category(source.name),
        "supported": supported,
        "reason": reason,
        "count": len(entries),
        "replacements": {},
        "catalog_version": TEXT_VERSION,
    }
    bank["text_stamp"] = attach_dialogue(
        game, source, raw, entries, project / "analysis/voices/text-index", **text_languages
    )
    if existing:
        bank["replacements"] = existing["replacements"]
        for field in ("custom", "import_path"):
            if field in existing:
                bank[field] = existing[field]
    plan["banks"][identity] = bank
    plan["last_selected_bank"] = identity
    _write(project / f"analysis/voices/catalog/{sha}.json", entries)
    _write(plan_path(project), plan)
    return {"bank": bank, "entries": entries, "plan": plan}


def import_assets(project, paths, label):
    from .metadata import read_track_metadata

    plan = load_plan(project)
    imported = []
    for value in paths:
        source = Path(value).expanduser().resolve()
        if not source.is_file() or source.suffix.lower() not in {
            ".wav",
            ".mp3",
            ".ogg",
            ".flac",
            ".m4a",
            ".aac",
            ".aiff",
        }:
            raise CliError("请选择本地音频素材。")
        meta = read_track_metadata(source)
        duration = float(
            meta.duration_sec
            or (meta.samples / meta.sample_rate if meta.samples and meta.sample_rate else 0)
        )
        if not math.isfinite(duration) or duration <= 0:
            raise CliError(f"无法读取素材时长：{source.name}")
        sha = digest(source)
        imported.append(sha)
        if any(a["id"] == sha for a in plan["assets"]):
            continue
        target = project / "sources/voices" / (sha + source.suffix.lower())
        _copy_snapshot(source, target)
        plan["assets"].append(
            {
                "id": sha,
                "name": source.stem,
                "source": project_path_or_absolute(project, target),
                "sha256": sha,
                "duration": duration,
                "category": str(label or "未分类")[:160],
            }
        )
    _write(plan_path(project), plan)
    return {"plan": plan, "asset_ids": imported}


def validate_edit(plan, edit):
    if not isinstance(edit, dict):
        raise CliError("替换设置格式无效。")
    asset = next((a for a in plan["assets"] if a["id"] == edit.get("asset_id")), None)
    if not asset:
        raise CliError("替换素材不存在，请重新选择。")
    if not isinstance(edit.get("keep_duration", False), bool):
        raise CliError("时长处理选项无效。")
    start, end, gain = [
        float(edit.get(k, default))
        for k, default in (("start", 0), ("end", asset["duration"]), ("gain_db", 0))
    ]
    if (
        not all(math.isfinite(n) for n in (start, end, gain))
        or not 0 <= start < end <= asset["duration"] + 0.001
        or not -6 <= gain <= 6
    ):
        raise CliError("裁剪范围或音量无效。")
    from .material_edit import validate_operations

    validate_operations(edit.get("audio_edits", []), end - start)
    return asset, start, end, gain


def _validated_replacements(plan, bank, replacements):
    """Use the same canonical fixed-index mapping at save and build time."""
    if not isinstance(replacements, dict) or (replacements and not bank["supported"]):
        raise CliError("此文件暂不支持替换。")
    normalized = {}
    for index, edit in replacements.items():
        text = str(index)
        try:
            number = int(text) if text.isdecimal() and not isinstance(index, bool) else -1
        except ValueError:
            number = -1
        if not 0 <= number < bank["count"]:
            raise CliError("替换条目编号无效。")
        key = str(number)
        if key in normalized:
            raise CliError(f"同一条目 {number + 1} 不能重复设置替换。")
        try:
            validate_edit(plan, edit)
        except (TypeError, ValueError, OverflowError) as error:
            raise CliError("裁剪范围或音量无效。") from error
        normalized[key] = copy.deepcopy(edit)
    return normalized


def save(project, changes):
    plan = load_plan(project)
    if not isinstance(changes, dict) or set(changes) - set(plan["banks"]):
        raise CliError("资源清单已变化，请重新选择文件。")
    for bank_id, replacements in changes.items():
        bank = plan["banks"][bank_id]
        bank["replacements"] = _validated_replacements(plan, bank, replacements)
    _write(plan_path(project), plan)
    return {"saved": True, "plan": plan}


def original(args, project, bank_id, index):
    bank = load_plan(project)["banks"].get(bank_id)
    if not bank or not 0 <= index < bank["count"]:
        raise CliError("请先确认并解析资源文件，再选择试听条目。")
    source = local_file(project, bank["source"])
    if digest(source) != bank["sha256"]:
        raise CliError("原音频备份已变化。")
    output = project / f"analysis/voices/original/{bank['sha256']}/{index + 1}.wav"
    if not output.is_file():
        output.parent.mkdir(parents=True, exist_ok=True)
        _run([_tool(args, "vgmstream-cli"), "-s", index + 1, "-o", output, source])
    return {"path": str(output)}


def render(args, project, plan, entry, edit, output):
    asset, start, end, gain = validate_edit(plan, edit)
    source = local_file(project, asset["source"])
    if digest(source) != asset["sha256"]:
        raise CliError("替换素材已变化，请重新导入。")
    output.parent.mkdir(parents=True, exist_ok=True)
    duration = end - start
    if edit.get("audio_edits"):
        from .material_edit import material_wave

        material = material_wave(args, project, asset, edit, namespace="voices")
        source, start, end = Path(material["path"]), 0, material["duration"]
        duration = end
    layout = "mono" if entry["channels"] == 1 else "stereo"
    samples = (
        entry["samples"]
        if edit.get("keep_duration", False)
        else max(1, round(duration * entry["frequency"]))
    )
    filters = f"atrim=start={start}:end={end},asetpts=PTS-STARTPTS,aresample={entry['frequency']},aformat=channel_layouts={layout},volume={gain}dB,apad,atrim=end_sample={samples}"
    _run(
        [
            _tool(args, "ffmpeg"),
            "-v",
            "error",
            "-y",
            "-i",
            source,
            "-af",
            filters,
            "-ar",
            entry["frequency"],
            "-ac",
            entry["channels"],
            "-c:a",
            "pcm_s16le",
            output,
        ]
    )
    return output


def freeze_for_build(args):
    value = getattr(args, "stinger_project", None)
    if not value:
        return None
    project = Path(value).resolve()
    plan = load_plan(project)
    if not plan["banks"]:
        return None
    record_file = project / ".fh-radio-studio/last_applied_package_manifest.json"
    record = json.loads(record_file.read_text(encoding="utf-8")) if record_file.is_file() else {}
    owned = {
        item.get("install_relative_path"): item.get("md5")
        for item in record.get("package_files", [])
    }
    game = game_root_for(Path(args.game_dir))
    checked_assets = set()
    assets = {asset["id"]: asset for asset in plan["assets"]}
    for bank in plan["banks"].values():
        bank["replacements"] = _validated_replacements(plan, bank, bank["replacements"])
        if bank["replacements"]:
            try:
                original = local_file(project, bank["source"])
                if digest(original) != bank["sha256"]:
                    raise CliError("原音频备份校验失败")
            except (CliError, OSError) as error:
                raise CliError(f"{bank['name']}：{error}；旧准备包已保留。") from error
        for index, edit in bank["replacements"].items():
            asset = assets[edit["asset_id"]]
            if asset["id"] in checked_assets:
                continue
            try:
                source = local_file(project, asset["source"])
                if digest(source) != asset["sha256"]:
                    raise CliError("素材内容已改变，请重新导入")
            except (CliError, OSError) as error:
                raise CliError(
                    f"{bank['name']} · 条目 {int(index) + 1}，素材「{asset.get('name', '未命名音频')}」："
                    f"{error}；旧准备包已保留。"
                ) from error
            checked_assets.add(asset["id"])
        relative = bank["relative_path"]
        current = effective_game_file(game, relative)
        owned_md5 = (
            owned.get(current.relative_to(game).as_posix())
            if current.is_relative_to(game)
            else None
        )
        bank["restore"] = False
        if not bank.get("replacements") and owned_md5 and md5_file(current) == owned_md5:
            original = local_file(project, bank["source"])
            bank["restore"] = owned_md5 != md5_file(original)
    # Keep an empty snapshot too, so a reused package cannot resurrect cleared voice files.
    return {"project": str(project), "plan": plan}


def compose_package(args):
    frozen = getattr(args, "_voice_snapshot", None)
    if not frozen:
        return
    project, plan = Path(frozen["project"]), frozen["plan"]
    package = Path(args.out_dir) / "package"
    records = []
    for bank in plan["banks"].values():
        if not bank["replacements"] and not bank.get("restore"):
            continue
        original_file = local_file(project, bank["source"])
        if digest(original_file) != bank["sha256"]:
            raise CliError(f"{bank['name']} 原音频备份校验失败。")
        raw = original_file.read_bytes()
        info, _, _, _ = read_bank(raw)
        changes = {}
        work_root = Path(args.out_dir) / "work/voices"
        folder = work_root / bank["id"]
        if not work_root.resolve().is_relative_to(
            Path(args.out_dir).resolve()
        ) or not folder.resolve().is_relative_to(work_root.resolve()):
            raise CliError("语音构建工作目录无效，旧准备包已保留。")
        for index_text, edit in bank["replacements"].items():
            index = int(index_text)
            sample = info.samples[index]
            entry = {
                "frequency": sample.frequency,
                "channels": sample.channels,
                "samples": sample.sample_count,
            }
            wav = folder / f"input-{index:05}/01.wav"
            render(args, project, plan, entry, edit, wav)
            output = folder / f"encoded-{index:05}"
            output.mkdir(parents=True, exist_ok=True)
            encoder_log = _run(
                [
                    _tool(args, "fsbankcl"),
                    "-write_peak_volume",
                    "-o",
                    output,
                    "-format",
                    "vorbis",
                    "-quality",
                    str(getattr(args, "quality", 50)),
                    "-recursive",
                    wav.parent,
                ]
            )
            encoded = list(output.rglob("*.fsb"))
            if len(encoded) != 1:
                raise CliError("编码器未生成唯一的单条语音结果：" + encoder_log[-1600:])
            changes[index] = encoded[0].read_bytes()
        rebuilt = replace_indices(raw, changes) if changes else raw
        destination = package / bank["relative_path"]
        if not destination.resolve().is_relative_to(package.resolve()):
            raise CliError("语音写入位置无效。")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(rebuilt)
        # Decode every changed entry from the finished bank, not the temporary FSB.
        import numpy as np
        import soundfile as sf

        for index in changes:
            check = folder / f"check-{index:05}.wav"
            _run([_tool(args, "vgmstream-cli"), "-s", index + 1, "-o", check, destination])
            actual, rate = sf.read(check, always_2d=True)
            expected, expected_rate = sf.read(folder / f"input-{index:05}/01.wav", always_2d=True)
            if (
                actual.shape != expected.shape
                or rate != expected_rate
                or float(np.sqrt(np.mean((actual - expected) ** 2))) > 0.1
            ):
                raise CliError(
                    f"{bank['name']} 条目 {index + 1} 的最终解码验证失败，旧准备包已保留。"
                )
        records.append(
            {
                "bank": bank["name"],
                "original_md5": md5_file(original_file),
                "restored": bool(bank.get("restore")),
                "replaced": len(changes),
                "unchanged_payloads_verified": True,
                "fixed_duration": all(
                    edit.get("keep_duration", False) for edit in bank["replacements"].values()
                ),
            }
        )
    manifest_path = package / "fh_radio_studio_package_manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["voices"] = {"schema_version": 1, "banks": records, "runtime_verified": False}
    _write(manifest_path, manifest)
    shutil.rmtree(Path(args.out_dir) / "work/voices", ignore_errors=True)


def cmd_voices(args):
    import sys

    from .file_lock import exclusive_file_lock

    if args.action == "serve":
        from . import material_edit  # Warm processing imports once per session.
        from .stinger_worker import serve

        return serve(args, handler=cmd_voices)

    project, game = Path(args.project_dir).resolve(), game_root_for(Path(args.game_dir))
    if not (project / ".fh-radio-studio/project.json").is_file():
        raise CliError("请先打开工程。")
    data = json.load(sys.stdin) if args.input_json == "-" else {}
    from . import voice_workspace as workspace
    from .voice_text import language_options

    with exclusive_file_lock(project / ".fh-radio-studio/voices.lock", timeout_sec=10):
        if args.action == "scan":
            result = scan(project, game, **language_options(data))
        elif args.action == "prepare":
            result = prepare(project, game, args.source, args, **language_options(data))
            if data.get("custom"):
                result["bank"].update(custom=True, import_path=str(Path(args.source).resolve()))
                _write(plan_path(project), result["plan"])
        elif args.action == "inspect":
            result = workspace.inspect(Path(args.source))
        elif args.action == "extract-assets":
            result = workspace.extract_assets(args, project, args.bank_id, data)
        elif args.action == "remove-assets":
            result = workspace.remove_assets(project, data)
        elif args.action == "asset-info":
            result = workspace.asset_information(args, project, args.asset_id)
        elif args.action == "export-text":
            result = workspace.export_text(project, game, data)
        elif args.action == "import":
            result = import_assets(project, args.paths, data.get("category"))
        elif args.action == "save":
            result = save(project, data.get("banks", {}))
        elif args.action == "decode-all":
            result = workspace.decode_all(args, project, args.bank_id)
        elif args.action == "folders":
            result = workspace.folders(project, data)
        elif args.action == "forget":
            result = workspace.forget(project, args.bank_id)
        elif args.action == "build-preview":
            result = workspace.package_summary(args, project, game)
        elif args.action == "build":
            result = workspace.build(args, project, game)
        elif args.action in {"deployment-preview", "deploy"}:
            result = workspace.deployment(args, project, game, data, write=args.action == "deploy")
        elif args.action == "original":
            result = original(args, project, args.bank_id, args.index)
        elif args.action == "preview":
            plan = load_plan(project)
            bank = plan["banks"][args.bank_id]
            entries = json.loads(
                (project / f"analysis/voices/catalog/{bank['sha256']}.json").read_text(
                    encoding="utf-8"
                )
            )
            key = hashlib.sha256(
                json.dumps([args.bank_id, args.index, data], sort_keys=True).encode()
            ).hexdigest()
            output = project / f"analysis/voices/previews/{key}.wav"
            if not output.is_file():
                render(args, project, plan, entries[args.index], data, output)
            result = {"path": str(output)}
        elif args.action == "update-asset":
            plan = load_plan(project)
            asset = next((a for a in plan["assets"] if a["id"] == args.asset_id), None)
            name, label = str(data.get("name", "")).strip(), str(data.get("category", "")).strip()
            if asset is None or not name or len(name) > 200:
                raise CliError("素材名称或分类无效。")
            label = workspace.folder_name(label)
            start = float(data.get("start", asset.get("start", 0)))
            end = float(data.get("end", asset.get("end", asset["duration"])))
            gain = float(data.get("gain_db", asset.get("gain_db", 0)))
            edits = data.get("audio_edits", asset.get("audio_edits", []))
            validate_edit(
                plan,
                {
                    "asset_id": asset["id"],
                    "start": start,
                    "end": end,
                    "gain_db": gain,
                    "audio_edits": edits,
                },
            )
            asset.update(name=name, category=label)
            asset.update(start=start, end=end, gain_db=gain, audio_edits=edits)
            _write(plan_path(project), plan)
            result = {"plan": plan}
        elif args.action == "asset":
            from .material_edit import material_wave
            from .stinger_cache import cached_wave

            plan = load_plan(project)
            asset = next((a for a in plan["assets"] if a["id"] == args.asset_id), None)
            if asset is None:
                raise CliError("素材不存在。")
            edit = {**asset, **data, "asset_id": asset["id"]}
            _, start, end, gain = validate_edit(plan, edit)
            if data.get("wave"):
                result = material_wave(args, project, asset, edit, namespace="voices")
            else:
                key = hashlib.sha256(json.dumps([asset, edit], sort_keys=True).encode()).hexdigest()
                output = project / f"analysis/voices/material-preview/{key}.wav"
                if not output.is_file():
                    from .material_edit import validate_operations

                    _, duration = validate_operations(edit.get("audio_edits", []), end - start)
                    render(
                        args,
                        project,
                        plan,
                        {"channels": 2, "frequency": 48000, "samples": round(duration * 48000)},
                        edit,
                        output,
                    )
                result = cached_wave(output)
        else:
            raise CliError("未知语音操作。")
        if args.action in {"scan", "import", "update-asset", "extract-assets"}:
            result = workspace.warm_materials(args, project, result)
    print(json.dumps(result, ensure_ascii=False, allow_nan=False))
    return 0
