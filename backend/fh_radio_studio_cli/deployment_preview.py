"""Describe the same validated file operations used by deployment."""

import re
from pathlib import Path

from .language import normalize_preferred_language, resolve_user_preferred_lang_path

_LANGUAGES = {
    "CHS": "简体中文",
    "CN": "简体中文",
    "CHT": "繁体中文",
    "TW": "繁体中文",
    "JP": "日语",
    "EN": "英语",
    "DE": "德语",
    "ES": "西班牙语",
    "MX": "拉丁美洲西班牙语",
    "BR": "巴西葡萄牙语",
    "IT": "意大利语",
    "KO": "韩语",
}


def _language(value):
    return _LANGUAGES.get(str(value).upper(), str(value))


def _description(item, manifest):
    name = Path(item["destination"]).name
    voice = next(
        (b for b in (manifest.get("voices") or {}).get("banks", []) if b.get("bank") == name), None
    )
    if voice and voice.get("restored"):
        return "恢复此文件的原有语音音频。"
    if voice:
        return f"自定义语音资源，替换 {voice['replaced']} 条；其他音频与原条目时长保持不变。"
    stinger = re.fullmatch(r"R(\d+)_Stingers_([^.]+)\.assets\.bank", name)
    if stinger:
        details = next(
            (b for b in (manifest.get("stingers") or {}).get("banks", []) if b.get("bank") == name),
            {},
        )
        prefix = f"第 {stinger[1]} 电台 · {_language(stinger[2])}台呼"
        if details.get("restored"):
            return f"{prefix}，恢复原有音频。"
        count = details.get("replaced")
        return (
            f"{prefix}，应用 {count} 条自建音频。" if count is not None else f"{prefix}的音频资源。"
        )
    music = re.fullmatch(r"R(\d+)_Tracks_.+\.assets\.bank", name)
    if music:
        restored = {str(r.get("radio")) for r in manifest.get("restored_radios", [])}
        return (
            f"恢复第 {music[1]} 电台的原版歌曲音频。"
            if music[1] in restored
            else f"第 {music[1]} 电台的歌曲音频。"
        )
    radioinfo = re.fullmatch(r"RadioInfo_([^.]+)\.xml", name)
    if radioinfo:
        return f"{_language(radioinfo[1])}电台配置，包含歌单、台呼标记和衔接时间。"
    if item.get("kind") == "string_table":
        language = manifest.get("language") or {}
        if language.get("source_lang") and language.get("target_lang"):
            return f"用于{_language(language['source_lang'])}显示、{_language(language['target_lang'])}语音的语言文本。"
        return "游戏界面的语言文本。"
    return "准备包中的游戏资源。"


def deployment_preview(
    args, game, package, manifest, validated_files, removals, *, excluded=frozenset(), issues=()
):
    from .deployment_selection import DEPLOYMENT_RECORD, PREFERRED_LANGUAGE

    writes = [
        {
            "file_name": Path(item["destination"]).name,
            "selection_id": item.get("selection_id", item["install_relative_path"]),
            "selected": item.get("selected", True),
            "path_base": "游戏目录",
            "destination": item["destination"],
            "relative_path": item["install_relative_path"],
            "description": _description(item, manifest),
            "category": "resource",
            "size_bytes": item["source_size"],
            "operation": "write",
        }
        for item in validated_files
    ]
    resource_count = len(writes)
    language = manifest.get("language") or {}
    if language.get("preferred_lang"):
        value = normalize_preferred_language(str(language["preferred_lang"]))
        destination = resolve_user_preferred_lang_path(getattr(args, "preferred_path", None))
        writes.append(
            {
                "file_name": destination.name,
                "selection_id": PREFERRED_LANGUAGE,
                "selected": PREFERRED_LANGUAGE not in excluded,
                "path_base": "语音设置目录",
                "destination": str(destination),
                "relative_path": "UserPreferredLang",
                "description": f"设置游戏使用的语音语言：{_language(value)}。",
                "category": "setting",
                "size_bytes": len(value.encode("utf-8")),
                "operation": "write",
            }
        )
    fingerprint = getattr(args, "last_applied_manifest", None)
    if fingerprint:
        destination = Path(fingerprint).expanduser().resolve()
        writes.append(
            {
                "file_name": destination.name,
                "selection_id": DEPLOYMENT_RECORD,
                "selected": DEPLOYMENT_RECORD not in excluded,
                "path_base": "工程目录",
                "destination": str(destination),
                "relative_path": ".fh-radio-studio/" + destination.name,
                "description": "记录本次写入结果，供之后校验和恢复使用。",
                "category": "record",
                "size_bytes": None,
                "operation": "write",
            }
        )
    delta = manifest.get("package_delta") or {}
    return {
        "schema_version": 1,
        "selection_issues": list(issues),
        "target_root": args.target_root,
        "package_dir": str(package),
        "game_dir": str(game),
        "resource_count": resource_count,
        "auxiliary_count": len(writes) - resource_count,
        "writes": writes,
        "removals": [
            {
                "file_name": path.name,
                "destination": str(path),
                "relative_path": path.relative_to(game).as_posix(),
                "description": "移除旧覆盖文件，使本次写入的游戏原文件生效。",
                "category": "resource",
                "size_bytes": path.stat().st_size,
                "operation": "remove",
            }
            for path in removals
        ],
        "changed_files_only": delta.get("mode") == "changed_files",
        "omitted_unchanged_count": len(delta.get("omitted_unchanged_files", [])),
    }
