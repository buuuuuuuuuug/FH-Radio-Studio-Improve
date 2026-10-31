"""Cached voice browsing, folders, bulk previews and a separate voice package."""

import argparse
import contextlib
import csv
import hashlib
import io
import json
import shutil
import tempfile
from pathlib import Path

from .common import CliError, md5_file
from .stingers import _run, _tool, _write, digest, local_file


def plan_stamp(plan):
    from .voices import _validated_replacements

    used = {e["asset_id"] for b in plan["banks"].values() for e in b["replacements"].values()}
    data = {
        "banks": {
            key: {
                "sha256": b["sha256"],
                "relative_path": b["relative_path"],
                # Legacy index spellings and the validated build snapshot
                # describe the same fixed targets and must share a stamp.
                "replacements": _validated_replacements(plan, b, b["replacements"]),
            }
            for key, b in plan["banks"].items()
            if b["replacements"]
        },
        "assets": {a["id"]: a["sha256"] for a in plan["assets"] if a["id"] in used},
    }
    return hashlib.sha256(json.dumps(data, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def asset_information(args, project, asset_id):
    from .stinger_cache import asset_source
    from .voices import load_plan

    plan = load_plan(project)
    asset = next((a for a in plan["assets"] if a["id"] == asset_id), None)
    if asset is None:
        raise CliError("素材不存在，请重新选择。")
    source = local_file(project, asset["source"])
    if not source.is_file() or digest(source) != asset["sha256"]:
        raise CliError("音频素材已改变，请重新导入。")
    return asset_source(args, project, asset, namespace="voices")


def warm_materials(args, project, result):
    """Return reusable playback data with the existing single CLI response."""
    from .material_edit import material_wave
    from .stinger_cache import asset_source

    for asset in result.get("plan", {}).get("assets", []):
        try:
            asset["source_preview"] = asset_source(args, project, asset, namespace="voices")
            asset["quick_preview"] = {
                **material_wave(args, project, asset, asset, namespace="voices"),
                "clip_gain": asset.get("gain_db", 0),
            }
        except (CliError, OSError, RuntimeError):
            # A damaged material must not prevent browsing other original banks.
            continue
    return result


def inspect(source):
    from .fsb5 import parse_fsb5_bytes

    if not source.is_file():
        raise CliError("文件不存在。")
    size = source.stat().st_size
    try:
        info = parse_fsb5_bytes(source.read_bytes(), max_samples=32768)
        decoded = sum(s.sample_count * s.channels * 2 + 44 for s in info.samples)
        return {
            "count": info.num_samples,
            "source_bytes": size,
            "decoded_bytes": decoded,
            "total_bytes": size + decoded,
            "estimated": True,
        }
    except CliError:
        return {
            "count": 0,
            "source_bytes": size,
            "decoded_bytes": 0,
            "total_bytes": size,
            "reason": "没有可识别的音频块；仅备份并记录限制原因。",
            "estimated": True,
        }


def extract_assets(args, project, bank_id, data):
    """Copy selected, verified original previews into the normal material pool."""
    import soundfile as sf

    from .common import CliError
    from .project_refs import project_path_or_absolute
    from .stingers import _copy_snapshot
    from .voices import load_plan, plan_path

    plan = load_plan(project)
    bank = plan["banks"].get(bank_id)
    indices = data.get("indices")
    if not bank or not isinstance(indices, list) or not indices:
        raise CliError("请先选择需要加入素材池的原音频。")
    if any(type(i) is not int or not 0 <= i < bank["count"] for i in indices):
        raise CliError("所选音频条目无效，请重新选择。")
    indices = sorted(set(indices))
    category = folder_name(data.get("category", "原音频"))
    source = local_file(project, bank["source"])
    if not source.is_file() or digest(source) != bank["sha256"]:
        raise CliError("原音频备份校验失败，未更改素材池。")
    entries = json.loads(
        (project / f"analysis/voices/catalog/{bank['sha256']}.json").read_text(encoding="utf-8")
    )
    by_index = {e["index"]: e for e in entries}
    if any(i not in by_index for i in indices):
        raise CliError("条目目录不完整，请重新解析资源。")
    folder = project / f"analysis/voices/original/{bank['sha256']}"
    if any(not (folder / f"{i + 1}.wav").is_file() for i in indices):
        decode_all(args, project, bank_id)
    # Validate all requested inputs before changing the saved plan.
    checked = []
    for index in indices:
        entry = by_index[index]
        path = folder / f"{index + 1}.wav"
        info = sf.info(path)
        if (info.frames, info.channels, info.samplerate) != (
            entry["samples"],
            entry["channels"],
            entry["frequency"],
        ):
            raise CliError(f"条目 {index + 1} 的原音频缓存校验失败，未更改素材池。")
        checked.append((index, entry, path, digest(path)))
    assets = {a["id"]: a for a in plan["assets"]}
    selected, previews = [], {}
    added = 0
    for index, entry, path, sha in checked:
        if sha not in assets:
            target = project / f"sources/voices/{sha}.wav"
            _copy_snapshot(path, target)
            asset = {
                "id": sha,
                "sha256": sha,
                "name": entry["name"],
                "source": project_path_or_absolute(project, target),
                "duration": entry["samples"] / entry["frequency"],
                "category": category,
            }
            plan["assets"].append(asset)
            assets[sha] = asset
            previews[sha] = str(target)
            added += 1
        origin = {"bank_id": bank_id, "index": index, "name": entry["name"]}
        origins = assets[sha].setdefault("origins", [])
        if origin not in origins:
            origins.append(origin)
        if sha not in selected:
            selected.append(sha)
    plan["folders"] = sorted(set(plan.get("folders", [])) | {category})
    _write(plan_path(project), plan)
    return {
        "plan": plan,
        "asset_ids": selected,
        "preview_paths": previews,
        "count": len(indices),
        "added": added,
        "reused": len(indices) - added,
    }


def export_text(project, game, data):
    from .voice_text import language_options
    from .voices import load_plan, prepare

    text_languages = language_options(data)

    sources = data.get("sources", [])
    if not isinstance(sources, list) or not sources:
        raise CliError("请先选择需要导出的资源文件。")
    fields = data.get("fields", ["name", "content", "translation", "duration"])
    labels = {
        "name": "条目",
        "content": "语音语言",
        "translation": "显示语言",
        "duration": "时长（秒）",
    }
    if not fields or set(fields) - set(labels):
        raise CliError("请选择有效的导出字段。")
    output = []
    rows = []
    count = 0
    for source in sources:
        existing = load_plan(project)["banks"].get(data.get("bank_id"))
        if existing:
            catalog = project / f"analysis/voices/catalog/{existing['sha256']}.json"
            if not catalog.is_file():
                raise CliError("此资源的解析目录已移除，请重新解析。")
            parsed = cached_catalogs(project, load_plan(project), game, **text_languages)[
                existing["id"]
            ]
        else:
            parsed = prepare(project, game, source, **text_languages)
        indices = data.get("indices")
        if indices is not None and (
            not isinstance(indices, list)
            or not indices
            or any(type(i) is not int or not 0 <= i < len(parsed["entries"]) for i in indices)
        ):
            raise CliError("请选择有效的音频条目。")
        indices = set(indices) if indices is not None else None
        output.append(f"【{parsed['bank']['name']}】")
        for entry in parsed["entries"]:
            if indices is not None and entry["index"] not in indices:
                continue
            if (
                data.get("matched_only")
                and not entry.get("content")
                and not entry.get("translation")
            ):
                continue
            row = [str(entry["index"] + 1)]
            for field in fields:
                value = entry.get(field, "")
                if field == "duration":
                    value = f"{value:.3f}"
                row.append(str(value).replace("\t", " ").replace("\r", " ").replace("\n", " "))
            output.append("\t".join(row))
            rows.append(row)
            count += 1
        output.append("")
    text = "序号\t" + "\t".join(labels[f] for f in fields) + "\n\n" + "\n".join(output)
    headers = ["序号", *(labels[f] for f in fields)]

    def delimited(delimiter):
        stream = io.StringIO(newline="")
        writer = csv.writer(stream, delimiter=delimiter, lineterminator="\r\n")

        def safe(value):
            return "'" + value if value.lstrip().startswith(("=", "+", "-", "@")) else value

        writer.writerow(headers)
        writer.writerows([[safe(v) for v in row] for row in rows])
        return stream.getvalue()

    result = {
        "text": text,
        "csv": delimited(","),
        "table_text": delimited("\t"),
        "headers": headers,
        "rows": rows,
        "count": count,
        "files": len(sources),
        "plan": load_plan(project),
    }
    if data.get("format") == "xlsx":
        from base64 import b64encode

        from .voice_xlsx import workbook_bytes

        result["xlsx_base64"] = b64encode(workbook_bytes(headers, rows)).decode("ascii")
    return result


def cached_catalogs(project, plan, game=None, **text_languages):
    result = {}
    changed = False
    for key, bank in plan["banks"].items():
        cache = project / f"analysis/voices/catalog/{bank['sha256']}.json"
        if cache.is_file():
            entries = json.loads(cache.read_text(encoding="utf-8"))
            if game is not None:
                from .voice_text import TEXT_VERSION, attach_dialogue, dialogue_stamp

                stamp = dialogue_stamp(game, Path(bank["name"]), **text_languages)
                if bank.get("catalog_version") != TEXT_VERSION or bank.get("text_stamp") != stamp:
                    source = local_file(project, bank["source"])
                    raw = source.read_bytes()
                    if hashlib.sha256(raw).hexdigest() != bank["sha256"]:
                        from .common import CliError

                        raise CliError("原音频备份校验失败，未更新字幕缓存。")
                    bank["text_stamp"] = attach_dialogue(
                        game,
                        Path(bank["name"]),
                        raw,
                        entries,
                        project / "analysis/voices/text-index",
                        **text_languages,
                    )
                    bank["catalog_version"] = TEXT_VERSION
                    _write(cache, entries)
                    changed = True
            folder = project / f"analysis/voices/original/{bank['sha256']}"
            for entry in entries:
                preview = folder / f"{entry['index'] + 1}.wav"
                if preview.is_file():
                    entry["preview_path"] = str(preview)
            result[key] = {
                "bank": bank,
                "entries": entries,
                "decoded": (folder / "ready.json").is_file(),
            }
    if changed:
        from .voices import plan_path

        _write(plan_path(project), plan)
    return result


def decode_all(args, project, bank_id):
    from .voices import load_plan

    bank = load_plan(project)["banks"].get(bank_id)
    if not bank or not bank["count"]:
        raise CliError("此文件没有可解码的音频条目。")
    source = local_file(project, bank["source"])
    if digest(source) != bank["sha256"]:
        raise CliError("原音频备份校验失败。")
    folder = project / f"analysis/voices/original/{bank['sha256']}"
    folder.mkdir(parents=True, exist_ok=True)
    marker = folder / "ready.json"
    expected = [folder / f"{i + 1}.wav" for i in range(bank["count"])]
    if not marker.is_file() or not all(p.is_file() and p.stat().st_size > 44 for p in expected):
        _run(
            [_tool(args, "vgmstream-cli"), "-i", "-s", 1, "-S", 0, "-o", folder / "?s.wav", source]
        )
        missing = [p.name for p in expected if not p.is_file() or p.stat().st_size <= 44]
        if missing:
            raise CliError(f"批量解码未完成，保留已完成缓存；缺少 {len(missing)} 条，可重试。")
        import soundfile as sf

        entries = json.loads(
            (project / f"analysis/voices/catalog/{bank['sha256']}.json").read_text(encoding="utf-8")
        )
        for entry, path in zip(entries, expected):
            decoded = sf.info(path)
            if (decoded.frames, decoded.channels, decoded.samplerate) != (
                entry["samples"],
                entry["channels"],
                entry["frequency"],
            ):
                raise CliError(
                    f"条目 {entry['index'] + 1} 的解码结果与原文件不一致；缓存未标记完成。"
                )
        _write(marker, {"sha256": bank["sha256"], "count": bank["count"]})
    return {
        "path": str(folder),
        "count": bank["count"],
        "complete": True,
        "paths": {str(i): str(p) for i, p in enumerate(expected)},
    }


def probe(path):
    try:
        with path.open("rb") as stream:
            header = stream.read(min(path.stat().st_size, 2 * 1024 * 1024))
        if b"FSB5" in header:
            return "待解析", ""
        if path.suffix.lower() in {".wav", ".ogg", ".mp3", ".flac"}:
            return "仅试听", "独立音频可试听；尚未验证重构写入。"
        return "无法解析", "事件／控制文件，未发现独立音频块；请打开对应的 assets.bank。"
    except OSError:
        return "无法解析", "文件无法读取。"


def folder_name(value):
    value = str(value or "未分类").strip().replace("\\", "/").strip("/")
    if (
        not value
        or len(value) > 160
        or any(p in {"", ".", ".."} or len(p) > 40 for p in value.split("/"))
    ):
        raise CliError("文件夹名称无效，请使用不含 .. 的分级名称。")
    return value


def folders(project, data):
    from .voices import load_plan, plan_path

    plan = load_plan(project)
    action = data.get("action", "create")
    name = folder_name(data.get("name"))
    choices = set(plan.get("folders", [])) | {a["category"] for a in plan["assets"]}
    if action == "create":
        choices.add(name)
    elif action == "move":
        ids = set(data.get("assets", []))
        if not ids or ids - {a["id"] for a in plan["assets"]}:
            raise CliError("所选素材已变化，请重新选择。")
        for asset in plan["assets"]:
            if asset["id"] in ids:
                asset["category"] = name
        choices.add(name)
    elif action == "rename":
        target = folder_name(data.get("target"))
        if target == name or target.startswith(name + "/"):
            raise CliError("不能把文件夹移动到自身内部。")
        for asset in plan["assets"]:
            if asset["category"] == name or asset["category"].startswith(name + "/"):
                asset["category"] = target + asset["category"][len(name) :]
        choices = {
            target + n[len(name) :] if n == name or n.startswith(name + "/") else n for n in choices
        }
    elif action == "delete":
        affected = {
            a["id"]
            for a in plan["assets"]
            if a["category"] == name or a["category"].startswith(name + "/")
        }
        if data.get("delete_assets", False):
            # Remove membership and references atomically. Imported immutable
            # source files stay available for recovery and cached packages.
            plan["assets"] = [a for a in plan["assets"] if a["id"] not in affected]
            for bank in plan["banks"].values():
                bank["replacements"] = {
                    i: e for i, e in bank["replacements"].items() if e["asset_id"] not in affected
                }
        else:
            for asset in plan["assets"]:
                if asset["id"] in affected:
                    asset["category"] = "未分类"
            if affected:
                choices.add("未分类")
        choices = {n for n in choices if n != name and not n.startswith(name + "/")}
    else:
        raise CliError("未知文件夹操作。")
    plan["folders"] = sorted(choices)
    _write(plan_path(project), plan)
    return {"plan": plan}


def remove_assets(project, data):
    """Remove pool membership and saved references together; keep source snapshots."""
    from .voices import load_plan, plan_path

    plan = load_plan(project)
    values = data.get("assets")
    if not isinstance(values, list) or not values or any(not isinstance(v, str) for v in values):
        raise CliError("请先选择要移除的素材。")
    ids = set(values)
    if ids - {a["id"] for a in plan["assets"]}:
        raise CliError("所选素材已变化，请重新选择。")
    removed_replacements = 0
    for bank in plan["banks"].values():
        previous = bank["replacements"]
        bank["replacements"] = {i: e for i, e in previous.items() if e["asset_id"] not in ids}
        removed_replacements += len(previous) - len(bank["replacements"])
    plan["assets"] = [a for a in plan["assets"] if a["id"] not in ids]
    _write(plan_path(project), plan)
    return {"plan": plan, "removed": len(ids), "removed_replacements": removed_replacements}


def forget(project, bank_id):
    from .voices import load_plan, plan_path

    plan = load_plan(project)
    bank = plan["banks"].get(bank_id)
    if not bank:
        raise CliError("解析记录不存在。")
    if bank["replacements"]:
        raise CliError("此文件仍有已保存的替换，请先恢复原音并保存。")
    sha = bank["sha256"]
    if len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha):
        raise CliError("缓存标识无效。")
    archive = project / f"backups/voices/removed-catalog-{bank_id}.json"
    _write(archive, bank)
    plan["banks"].pop(bank_id)
    if plan.get("last_selected_bank") == bank_id:
        plan.pop("last_selected_bank")
    _write(plan_path(project), plan)
    (project / f"analysis/voices/catalog/{sha}.json").unlink(missing_ok=True)
    folder = project / f"analysis/voices/original/{sha}"
    if (
        folder.is_dir()
        and not folder.is_symlink()
        and folder.resolve().is_relative_to((project / "analysis/voices").resolve())
    ):
        shutil.rmtree(folder)
    return {"plan": plan, "removed": True}


def package_summary(args, project, game):
    from .voices import freeze_for_build

    snapshot = freeze_for_build(
        argparse.Namespace(stinger_project=str(project), game_dir=str(game))
    )
    banks = [
        b
        for b in (snapshot or {"plan": {"banks": {}}})["plan"]["banks"].values()
        if b["replacements"] or b.get("restore")
    ]
    return {
        "files": [
            {
                "name": b["name"],
                "relative_path": b["relative_path"],
                "replaced": len(b["replacements"]),
                "restore": b.get("restore", False),
            }
            for b in banks
        ],
        "package_dir": str(project / "packages/voices-current/package"),
    }


def build(args, project, game):
    import uuid

    from .package import package_file_fingerprints
    from .package_transaction import publish_inplace, recover_inplace
    from .voices import compose_package, freeze_for_build

    target = project / "packages/voices-current"
    target.parent.mkdir(parents=True, exist_ok=True)
    recover_inplace(target)
    snapshot = freeze_for_build(
        argparse.Namespace(stinger_project=str(project), game_dir=str(game))
    )
    if not package_summary(args, project, game)["files"]:
        raise CliError("没有需要构建的语音替换或恢复记录。")
    with tempfile.TemporaryDirectory(prefix=".voices-build-", dir=target.parent) as temp:
        stage = Path(temp)
        package = stage / "package"
        package.mkdir()
        manifest = {
            "schema_version": 1,
            "game": "FH6",
            "game_dir": str(game),
            "package_delta": {"mode": "changed_files"},
            "runtime_verified": False,
        }
        _write(package / "fh_radio_studio_package_manifest.json", manifest)
        build_args = argparse.Namespace(**vars(args))
        build_args.out_dir = str(stage)
        build_args._voice_snapshot = snapshot
        compose_package(build_args)
        manifest = json.loads(
            (package / "fh_radio_studio_package_manifest.json").read_text(encoding="utf-8")
        )
        manifest["voices"]["plan_sha256"] = plan_stamp(snapshot["plan"])
        manifest["package_files"] = package_file_fingerprints(package)
        _write(package / "fh_radio_studio_package_manifest.json", manifest)
        if target.exists():
            publish_inplace(
                target, stage, target.with_name(f".{target.name}-previous-{uuid.uuid4().hex}")
            )
        else:
            shutil.copytree(stage, target)
    return {"built": True, **package_summary(args, project, game)}


def deployment(args, project, game, data, *, write=False):
    from .deploy import cmd_deploy_package
    from .voices import load_plan

    if write:
        from .game import is_forza_running

        if is_forza_running():
            raise CliError("请先退出游戏，再写入语音准备包。")
    package = project / "packages/voices-current/package"
    if not (package / "fh_radio_studio_package_manifest.json").is_file():
        raise CliError("请先构建语音准备包。")
    manifest = json.loads(
        (package / "fh_radio_studio_package_manifest.json").read_text(encoding="utf-8")
    )
    if manifest.get("voices", {}).get("plan_sha256") != plan_stamp(load_plan(project)):
        raise CliError("保存的语音替换已变化，请重新构建后再写入。")
    # Use immutable voice originals as the narrow baseline for this independent package.
    baseline = project / "analysis/voices/deployment-baseline.json"
    _write(
        baseline,
        {
            "files": [
                {
                    "install_relative_path": b["relative_path"],
                    "md5": md5_file(local_file(project, b["source"])),
                }
                for b in load_plan(project)["banks"].values()
            ]
        },
    )
    call = argparse.Namespace(
        game_dir=str(game),
        package_dir=str(package),
        target_root=data.get("target", "mediapc"),
        force=False,
        yes=write,
        json=not write,
        exclude_file=data.get("excluded", []),
        baseline_manifest=str(baseline),
        preferred_path=None,
        last_applied_manifest=str(project / ".fh-radio-studio/last_applied_package_manifest.json"),
    )
    if call.target_root not in {"media", "mediapc"}:
        raise CliError("写入位置无效。")
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        cmd_deploy_package(call)
    return {"written": True} if write else json.loads(output.getvalue())
