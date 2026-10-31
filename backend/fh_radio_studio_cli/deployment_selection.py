"""Validate explicit file choices against the resulting game configuration."""

import re
import xml.etree.ElementTree as ET
from pathlib import Path

from .common import CliError, md5_file
from .deployment_paths import effective_game_file
from .package_delta import _music_part, semantic_xml

PREFERRED_LANGUAGE = "@preferred-language"
DEPLOYMENT_RECORD = "@deployment-record"


def excluded_files(args, files, manifest):
    excluded = set(getattr(args, "exclude_file", None) or [])
    known = {str(f["install_relative_path"]) for f in files}
    if (manifest.get("language") or {}).get("preferred_lang"):
        known.add(PREFERRED_LANGUAGE)
    if getattr(args, "last_applied_manifest", None):
        known.add(DEPLOYMENT_RECORD)
    unknown = excluded - known
    if unknown:
        raise CliError("写入清单已变化，请重新读取：" + "、".join(sorted(unknown)))
    return excluded


def selection_issues(files, excluded, game):
    resources = {str(f["package_install_relative_path"]): f for f in files}
    if not excluded.intersection(resources):
        return []
    selected = set(resources) - excluded
    issues = []
    for xml_path, xml in resources.items():
        if not re.fullmatch(r"RadioInfo_.+\.xml", Path(xml_path).name):
            continue
        before_path = effective_game_file(game, xml_path)
        if not before_path.is_file():
            if selected and xml_path not in selected:
                issues.append(f"请同时勾选 {Path(xml_path).name}，游戏中缺少对应配置。")
            continue
        before = ET.parse(before_path).getroot()
        after = ET.parse(xml["source"]).getroot()
        for station in after.iter("RadioStation"):
            number = station.get("Number")
            previous = before.find(f".//RadioStation[@Number='{number}']")
            for kind in ("Stingers", "Tracks"):
                prefix = f"R{number}_{kind}_"

                def section(node):
                    if node is None:
                        return None
                    nodes = [
                        c
                        for c in node
                        if (
                            c.tag == "SampleList" and c.get("Type") == "Stinger"
                            if kind == "Stingers"
                            else _music_part(c)
                        )
                    ]
                    banks = node.find("Banks")
                    if banks is not None:
                        nodes += [c for c in banks if c.get("Name", "").startswith(prefix)]
                    return [semantic_xml(c) for c in nodes]

                if section(previous) == section(station):
                    continue
                banks = [path for path in resources if Path(path).name.startswith(prefix)]
                for bank in banks:
                    changed = md5_file(effective_game_file(game, bank)) != md5_file(
                        Path(resources[bank]["source"])
                    )
                    if not changed:
                        continue
                    if bank in selected and xml_path not in selected:
                        issues.append(
                            f"{Path(bank).name} 的条目或时间点已变化，请同时勾选 {Path(xml_path).name}。"
                        )
                    if xml_path in selected and bank not in selected:
                        issues.append(
                            f"{Path(xml_path).name} 引用了新的音频配置，请同时勾选 {Path(bank).name}。"
                        )
    return list(dict.fromkeys(issues))
