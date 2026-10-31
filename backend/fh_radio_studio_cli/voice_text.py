"""Read-only subtitle linkage: exact sound hash -> dialogue event -> string ID.

Section layout reference (independent bounded reader, no writer):
https://github.com/7akeem0/forzatech-localization-toolkit/blob/main/docs/str_format.md
"""

import hashlib
import json
import re
import struct
import xml.etree.ElementTree as ET
import zipfile
from functools import lru_cache
from pathlib import Path

from .bank_expansion import sound_hash


def string_values(raw):
    if len(raw) < 0x98 or raw[:2] != b"\0\x08":
        return {}
    offset = struct.unpack_from("<I", raw, 0x84)[0]
    if not 0x8C <= offset <= len(raw) - 12:
        return {}
    size, blob_size, count = struct.unpack_from("<III", raw, offset)
    blob = offset + 12 + count * 8
    payload_size = count * 8 + blob_size
    # Shipping FH6 sections exclude their 12-byte section header from this field.
    if (
        count > 1000000
        or size not in {payload_size, 12 + payload_size}
        or blob + blob_size > len(raw)
    ):
        return {}
    result = {}
    for i in range(count):
        key, position = struct.unpack_from("<II", raw, offset + 12 + i * 8)
        if position >= blob_size:
            return {}
        end = raw.find(b"\0", blob + position, blob + blob_size)
        if end < 0:
            return {}
        result[key] = raw[blob + position : end].decode("utf-8")
    return result


TEXT_VERSION = 6


def subtitle_text(value):
    """Unwrap only the game's BOLD formatting; preserve other bracketed tokens."""
    text = str(value or "")
    result = []
    position = 0
    while position < len(text):
        if text[position : position + 6].upper() != "[BOLD:":
            result.append(text[position])
            position += 1
            continue
        depth, end = 1, position + 6
        while end < len(text) and depth:
            if text[end] == "[":
                depth += 1
            elif text[end] == "]":
                depth -= 1
            end += 1
        if depth:
            result.append(text[position:])
            break
        result.append(subtitle_text(text[position + 6 : end - 1]))
        position = end
    return "".join(result)


def _locale(source):
    match = re.search(r"_([A-Z]{2,3})(?:\.assets)?\.(?:bank|fsb|wav)$", Path(source).name)
    return match[1] if match else "EN"


def _language(slot):
    return {"CN": "CHS", "TW": "CHT"}.get(slot, slot)


def language_options(data):
    """Keep text languages separate from the bank's sound-name locale."""
    result = {}
    for key in ("voice_language", "display_language"):
        value = data.get(key)
        if value is not None:
            if not isinstance(value, str) or not re.fullmatch(r"[A-Z]{2,3}", value):
                from .common import CliError

                raise CliError("请选择有效的语音语言和显示语言。")
            result[key] = _language(value)
    return result


def _languages(source, voice_language, display_language):
    return _language(voice_language or _locale(source)), _language(display_language)


def _inputs(game, voice_language, display_language):
    game = Path(game)
    scripts = sorted((game / "media/audio").glob("Dialogue*.xml"))
    archives = [
        game / f"media/Stripped/StringTables/{lang}.zip"
        for lang in sorted({voice_language, display_language})
    ]
    return scripts, archives


def dialogue_stamp(game, source, *, voice_language=None, display_language="CHS"):
    languages = _languages(source, voice_language, display_language)
    scripts, archives = _inputs(game, *languages)
    records = [
        (str(p.resolve()), p.stat().st_size, p.stat().st_mtime_ns)
        for p in scripts + archives
        if p.is_file()
    ]
    return hashlib.sha256(
        json.dumps([TEXT_VERSION, languages, records], sort_keys=True).encode()
    ).hexdigest()


def _stem(name):
    name = str(name).replace("\\", "/").rsplit("/", 1)[-1]
    return name[:-4] if name.lower().endswith(".wav") else name


def _subtitle_id(value):
    try:
        value = str(value or "")
        number = int(value, 16 if value.lower().startswith("0x") else 10)
        return number if 0 <= number <= 0xFFFFFFFF else None
    except ValueError:
        return None


@lru_cache(maxsize=8)
def _index(game, voice_language, display_language, stamp, cache_dir):
    cache = Path(cache_dir) / f"{voice_language}-{display_language}.json" if cache_dir else None
    if cache and cache.is_file():
        try:
            data = json.loads(cache.read_text(encoding="utf-8"))
            if data.get("stamp") == stamp:
                return data
        except (OSError, ValueError):
            pass
    scripts, archives = _inputs(game, voice_language, display_language)
    tables = {}
    for archive_path in archives:
        language = archive_path.stem
        tables[language] = {}
        if not archive_path.is_file():
            continue
        try:
            with zipfile.ZipFile(archive_path) as archive:
                for name in archive.namelist():
                    base = name.replace("\\", "/").rsplit("/", 1)[-1]
                    if base.lower().startswith("dialogue") and base.lower().endswith(".str"):
                        tables[language][base.lower()] = {
                            str(k): v for k, v in string_values(archive.read(name)).items()
                        }
        except (OSError, ValueError, KeyError, zipfile.BadZipFile):
            continue
    records = []
    for script in scripts:
        try:
            tree = ET.parse(
                script, parser=ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
            )
        except (ET.ParseError, OSError):
            continue
        table = (
            "dialogue.str"
            if script.stem.lower() == "dialoguescript"
            else script.stem.lower() + ".str"
        )
        for parent in tree.getroot().iter():
            children = list(parent)
            for position, child in enumerate(children):
                if child.tag == "Event":
                    stem = _stem(child.get("name", ""))
                    if stem:
                        records.append(
                            {
                                "stem": stem,
                                "sub": _subtitle_id(child.get("sub")),
                                "table": table,
                                "script": script.name,
                                "comment": "",
                            }
                        )
                if child.tag is not ET.Comment:
                    continue
                text = child.text or ""
                wav = re.search(r'WAV\s+File\s*:\s*"([^"\n]+)"', text, re.I)
                subtitle = re.search(r'Subtitle\s*:\s*"(.*)"\s*$', text, re.S | re.I)
                if not wav:
                    continue
                stem = _stem(wav[1])
                following = []
                for sibling in children[position + 1 :]:
                    if sibling.tag is ET.Comment:
                        break
                    if sibling.tag == "Event":
                        following.append(sibling)
                exact = [e for e in following if _stem(e.get("name", "")) == stem]
                event = (
                    exact[0] if len(exact) == 1 else following[0] if len(following) == 1 else None
                )
                records.append(
                    {
                        "stem": stem,
                        "sub": _subtitle_id(event.get("sub")) if event is not None else None,
                        "table": table,
                        "script": script.name,
                        "comment": subtitle[1] if subtitle else "",
                    }
                )
    data = {"stamp": stamp, "records": records, "tables": tables}
    if cache:
        from .stingers import _write

        _write(cache, data)
    return data


def _resolve(tables, sub_id, preferred):
    if sub_id is None:
        return "", ""
    key = str(sub_id)
    if tables.get(preferred, {}).get(key):
        return tables[preferred][key], preferred
    matches = {name: rows[key] for name, rows in tables.items() if rows.get(key)}
    if len(set(matches.values())) == 1:
        return next(iter(matches.values())), ", ".join(sorted(matches))
    return "", ""


def attach_dialogue(
    game, source, raw, entries, cache_dir=None, *, voice_language=None, display_language="CHS"
):
    """Exact bank sound hash -> subtitle ID -> the two requested language tables."""
    from .bank_expansion import _find, _read_stbl

    try:
        _, start, end = _find(raw, b"STBL")
        lookup = _read_stbl(raw[start:end])
    except Exception:
        lookup = {sound_hash(e["name"]): e["index"] for e in entries if e.get("name")}
    slot = _locale(source)
    voice_language, display_language = _languages(source, voice_language, display_language)
    stamp = dialogue_stamp(
        game, source, voice_language=voice_language, display_language=display_language
    )
    data = _index(
        str(Path(game).resolve()), voice_language, display_language, stamp, str(cache_dir or "")
    )
    tables = data["tables"]
    matches = {}
    valid = {e["index"] for e in entries}
    for record in data["records"]:
        for name in (record["stem"] + "_" + slot, record["stem"]):
            index = lookup.get(sound_hash(name))
            if index not in valid:
                continue
            content, own_table = _resolve(
                tables.get(voice_language, {}), record["sub"], record["table"]
            )
            translation, display_table = _resolve(
                tables.get(display_language, {}), record["sub"], record["table"]
            )
            comment = False
            if not content and voice_language == "EN" and record["comment"]:
                content, comment = record["comment"], True
            result = {
                "name": name,
                "content": subtitle_text(content),
                "translation": subtitle_text(translation),
                "subtitle_id": record["sub"],
                "content_language": voice_language,
                "translation_language": display_language,
                "text_source": f"{record['script']} / {own_table or record['table']} / {record['sub']}",
                "translation_source": display_table,
                "text_source_type": "script-comment" if comment else "language-table",
            }
            if result["content"] != content:
                result["content_raw"] = content
            if result["translation"] != translation:
                result["translation_raw"] = translation
            matches.setdefault(index, []).append(result)
    for entry in entries:
        for key in (
            "content",
            "translation",
            "subtitle_id",
            "text_source",
            "translation_source",
            "content_language",
            "translation_language",
            "text_source_type",
            "content_raw",
            "translation_raw",
        ):
            entry.pop(key, None)
        candidates = matches.get(entry["index"], [])
        rank = lambda r: (
            bool(r["content"]) + bool(r["translation"]),
            r["text_source_type"] == "language-table",
        )
        if candidates:
            best_rank = max(map(rank, candidates))
            best = [r for r in candidates if rank(r) == best_rank]
            if len({(r["content"], r["translation"]) for r in best}) > 1:
                entry["text_reason"] = "同一音频关联了不同字幕，未自动选择。"
                continue
            entry.update(best[0])
        entry["text_reason"] = (
            "未在游戏对白索引中找到该音频的字幕关联。"
            if not candidates
            else (
                "对白索引存在，但语言表没有提供对应文本。"
                if not entry.get("content") and not entry.get("translation")
                else (
                    "语音语言表没有提供文本；可查看或复制显示语言文本。"
                    if not entry.get("content")
                    else (
                        "显示语言表未提供该条文本。"
                        if not entry.get("translation")
                        else (
                            "使用游戏脚本英文注释。"
                            if entry.get("text_source_type") == "script-comment"
                            else ""
                        )
                    )
                )
            )
        )
    return stamp
