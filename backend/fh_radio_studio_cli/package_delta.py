"""Publish only intended changes while preserving live, unrelated RadioInfo data."""

from __future__ import annotations

import copy
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

from .common import CliError, md5_file
from .deployment_paths import contained_game_path, effective_game_file
from .game import game_root_for


def semantic_xml(node):
    return (
        node.tag,
        sorted(node.attrib.items()),
        (node.text or "").strip(),
        [semantic_xml(child) for child in node],
    )


def _music_part(node):
    return (
        node.tag == "SampleList"
        and node.get("Type") == "Track"
        or (node.tag == "PlayList" and node.get("Type") in {"FreeRoam", "Event"})
    )


def _replace_music(live, intended, radio):
    for child in intended:
        if not _music_part(child):
            continue
        previous = next(
            (x for x in live if x.tag == child.tag and x.get("Type") == child.get("Type")), None
        )
        if previous is not None and semantic_xml(previous) == semantic_xml(child):
            continue
        index = list(live).index(previous) if previous is not None else len(live)
        if previous is not None:
            live.remove(previous)
        live.insert(index, copy.deepcopy(child))
    # Keep DJ/stinger bank references and all station attributes from the game.
    banks = live.find("Banks")
    planned_banks = intended.find("Banks")
    if planned_banks is not None:
        if banks is None:
            banks = ET.SubElement(live, "Banks")
        prefix = f"R{radio}_Tracks"
        current_music = [child for child in banks if child.get("Name", "").startswith(prefix)]
        new_music = [child for child in planned_banks if child.get("Name", "").startswith(prefix)]
        if [semantic_xml(x) for x in current_music] != [semantic_xml(x) for x in new_music]:
            index = list(banks).index(current_music[0]) if current_music else len(banks)
            for child in current_music:
                banks.remove(child)
            for offset, child in enumerate(new_music):
                banks.insert(index + offset, copy.deepcopy(child))


def prepare_radioinfo_base(args):
    """Merge only planned music into live XML before the stinger patch runs."""
    if not getattr(args, "game_dir", None):
        return
    game = game_root_for(Path(args.game_dir))
    if not game.is_dir():
        raise CliError("游戏目录不存在，无法核对本次准备包的改动范围")
    package = Path(args.out_dir) / "package"
    manifest = json.loads(
        (package / "fh_radio_studio_package_manifest.json").read_text(encoding="utf-8")
    )
    radios = {
        str(unit["radio"]) for unit in manifest.get("radios", []) if unit.get("radio") is not None
    }
    bases = {}
    changed_music_radios = set()
    for xml in (package / "media/audio").glob("RadioInfo_*.xml"):
        relative = xml.relative_to(package).as_posix()
        current = effective_game_file(game, relative)
        if not current.is_file():
            continue
        before = md5_file(current)
        live, planned = ET.parse(current), ET.parse(xml)
        by_number = {
            station.get("Number"): station for station in planned.getroot().iter("RadioStation")
        }
        for station in live.getroot().iter("RadioStation"):
            radio = station.get("Number")
            if radio in radios and radio in by_number:
                before_music = semantic_xml(station)
                _replace_music(station, by_number[radio], radio)
                if semantic_xml(station) != before_music:
                    changed_music_radios.add(int(radio))
        ET.indent(live, space="  ")
        live.write(xml, encoding="utf-8", xml_declaration=True)
        bases[relative] = before
    args._delta_changed_music_radios = changed_music_radios
    args._delta_music_radios = radios
    args._delta_game = game
    args._delta_radioinfo_bases = bases


def finalize_changed_files(args):
    """Drop unchanged output, retain dependency hashes for a safe later write."""
    if not hasattr(args, "_delta_game"):
        return
    from .package import collect_package_deploy_files, package_file_fingerprints
    from .project_json_guard import write_project_json

    package = Path(args.out_dir) / "package"
    manifest_path = package / "fh_radio_studio_package_manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    game = args._delta_game
    omitted, excluded, dependencies, guards = [], [], [], []
    music_radios = args._delta_music_radios
    stinger_banks = {bank["bank"] for bank in (manifest.get("stingers") or {}).get("banks", [])}
    voice_banks = {bank["bank"] for bank in (manifest.get("voices") or {}).get("banks", [])}
    language = manifest.get("language") or {}
    target_table = str(language.get("target_lang") or "") + ".zip"
    for relative, before in args._delta_radioinfo_bases.items():
        if md5_file(effective_game_file(game, relative)) != before:
            raise CliError(f"{Path(relative).name} 在构建期间发生变化，请重新构建；旧准备包已保留")
    for item in collect_package_deploy_files(package, require_files=False):
        source = Path(item["source"])
        relative = item["install_relative_path"]
        if (
            source.is_symlink()
            or source.resolve() != contained_game_path(package, relative).resolve()
        ):
            raise CliError("准备包改动检查包含无效路径")
        music = re.fullmatch(r"R(\d+)_Tracks_.+\.assets\.bank", source.name)
        unrequested = source.suffix == ".bank" and not (
            music
            and music.group(1) in music_radios
            or source.name in stinger_banks
            or source.name in voice_banks
        )
        unrequested |= item["kind"] == "string_table" and source.name != target_table
        if unrequested:
            excluded.append(relative)
            source.unlink()
            continue
        current = effective_game_file(game, relative)
        intended_md5, current_md5 = md5_file(source), md5_file(current)
        same = current_md5 is not None and intended_md5 == current_md5
        is_radioinfo = source.name.startswith("RadioInfo_") and source.suffix == ".xml"
        if is_radioinfo and current_md5 is not None:
            same = semantic_xml(ET.parse(source).getroot()) == semantic_xml(
                ET.parse(current).getroot()
            )
        if same:
            omitted.append(relative)
            if source.suffix == ".bank":
                dependencies.append({"install_relative_path": relative, "md5": current_md5})
            source.unlink()
        elif relative in args._delta_radioinfo_bases:
            guards.append(
                {
                    "install_relative_path": relative,
                    "before_md5": args._delta_radioinfo_bases[relative],
                    "after_md5": intended_md5,
                }
            )
    files = package_file_fingerprints(package, require_files=False)
    manifest["package_files"] = files
    bank_names = [
        Path(item["relative_path"]).name
        for item in files
        if str(item["relative_path"]).endswith(".bank")
    ]
    bank_radios = {
        int(match.group(1)) for name in bank_names if (match := re.match(r"R(\d+)_", name))
    }
    changed_music = args._delta_changed_music_radios | {
        int(match.group(1)) for name in bank_names if (match := re.match(r"R(\d+)_Tracks_", name))
    }
    restored = [
        unit for unit in manifest.get("restored_radios", []) if int(unit["radio"]) in changed_music
    ]
    if "restored_radios" in manifest:
        manifest["restored_radios"] = restored
        manifest["baseline_restore"] = bool(restored)
    manifest["target_bank_name"] = ", ".join(sorted(bank_names))
    if len(bank_radios) == 1:
        manifest["radio"] = next(iter(bank_radios))
        manifest["station"] = (
            next(
                (
                    unit.get("station")
                    for unit in manifest.get("radios", [])
                    if unit.get("radio") == manifest["radio"]
                ),
                None,
            )
            or f"R{manifest['radio']} · 电台台呼"
        )
    manifest["package_delta"] = {
        "schema_version": 1,
        "mode": "changed_files",
        "no_changes": not files,
        "omitted_unchanged_files": omitted,
        "excluded_unrequested_files": excluded,
        "bank_dependencies": dependencies,
        "radioinfo_guards": guards,
        "file_count": len(files),
        "bank_count": sum(str(item["relative_path"]).endswith(".bank") for item in files),
    }
    write_project_json(
        manifest_path,
        manifest,
        project_dir=Path((args._stinger_snapshot or args._voice_snapshot)["project"]),
    )
    write_install_note(package, files)
    print(
        f"仅保留实际改动：{len(files)} 个文件；省略 {len(omitted)} 个与游戏一致的文件。", flush=True
    )


def write_install_note(package, files):
    text = [
        "FH Radio Studio · 改动准备包",
        "",
        "仅包含实际变化的资源及必要配置；与游戏一致的文件已省略。",
        "请通过工具写入游戏。构建后如游戏配置发生变化，请重新构建准备包。",
        "",
        f"本次资源文件：{len(files)} 个",
        *[str(item["install_relative_path"]) for item in files],
    ]
    (package / "INSTALL_README.txt").write_text("\n".join(text) + "\n", encoding="utf-8")


def validate_delta_dependencies(manifest, game, *, xml_paths=None):
    """A compact package must not overwrite a shared XML changed after build."""
    delta = manifest.get("package_delta") or {}
    if delta.get("mode") != "changed_files":
        return
    for item in delta.get("bank_dependencies", []):
        relative = item["install_relative_path"]
        if md5_file(effective_game_file(game, relative)) != item["md5"]:
            raise CliError(
                f"{Path(relative).name} 与构建时不一致，请重新构建准备包后再写入；尚未写入任何文件"
            )
    for item in delta.get("radioinfo_guards", []):
        relative = item["install_relative_path"]
        if xml_paths is not None and relative not in xml_paths:
            continue
        if md5_file(effective_game_file(game, relative)) not in {
            item["before_md5"],
            item["after_md5"],
        }:
            raise CliError(
                f"{Path(relative).name} 在构建后发生变化，请重新构建，避免覆盖其他修改；尚未写入任何文件"
            )
