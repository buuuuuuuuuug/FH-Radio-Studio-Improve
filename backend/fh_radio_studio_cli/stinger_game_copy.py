"""Copy the actual game stinger audio/order into a reversible project draft."""

import copy
import xml.etree.ElementTree as ET
from pathlib import Path

from .common import CliError
from .game import game_root_for


def copy_game(args, project, game, locale, *, draft_only=False):
    from .stingers import (
        _pin_baseline,
        _read_catalog,
        _write,
        digest,
        import_audio,
        load_plan,
        local_file,
        original_preview,
        plan_path,
    )

    game = game_root_for(game)
    saved = plan_path(project).read_bytes() if plan_path(project).exists() else None
    plan = load_plan(project)
    persisted = copy.deepcopy(plan)
    original_assets = len(plan["assets"])
    live = _read_catalog(project, game, locale, current_game=True)
    try:
        for station in live["stations"]:
            key = station["key"]
            baseline = plan["baselines"].get(key)
            base_bank = Path(game) / "media/audio/FMODBanks" / station["bank_name"]
            original_hash = baseline["sha256"] if baseline else digest(base_bank)
            original = (
                (
                    next(
                        s
                        for s in ET.parse(local_file(project, baseline["xml_ref"]))
                        .getroot()
                        .iter("RadioStation")
                        if s.get("Number") == str(station["radio"])
                    )
                    .find("SampleList[@Type='Stinger']")
                    .findall("Sample")
                )
                if baseline
                else station["slots"]
            )
            if len(station["slots"]) != len(original):
                raise CliError("游戏内台呼数量与原始数量不同，不能复制到固定台呼位置。")
            plan["assignments"] = {
                k: v for k, v in plan["assignments"].items() if not k.startswith(key + ":")
            }
            if station["bank_sha256"] == original_hash:
                continue
            _pin_baseline(project, plan, station, locale)
            for order, slot in enumerate(station["slots"], 1):
                audio = original_preview(args, project, station, slot)
                # Import is authoritative and keeps every sample and cue position.
                _write(plan_path(project), plan)
                imported = import_audio(project, [audio["path"]])
                plan["assets"] = imported["assets"]
                asset = next(
                    a for a in plan["assets"] if a["sha256"] == digest(Path(audio["path"]))
                )
                asset["name"] = f"游戏台呼 R{station['radio']} · {order:02}"
                name = original[order - 1].get("SoundName")
                plan["assignments"][f"{key}:{name}"] = {
                    "asset_id": asset["id"],
                    "start": 0.0,
                    "end": asset["duration"],
                    "gain_db": 0.0,
                    "next_track": slot["next_track"],
                }
        data = _read_catalog(project, game, locale, plan_override=plan) if draft_only else None
        if draft_only:
            known = {a["id"] for a in persisted["assets"]}
            persisted["assets"].extend(a for a in plan["assets"] if a["id"] not in known)
            persisted["baselines"] = plan["baselines"]
            _write(plan_path(project), persisted)
        else:
            _write(plan_path(project), plan)
    except Exception:
        if saved is not None:
            plan_path(project).write_bytes(saved)
        else:
            plan_path(project).unlink(missing_ok=True)
        raise
    return {
        "saved": True,
        "assignment_count": len(plan["assignments"]),
        "needs_cache": len(plan["assets"]) > original_assets,
        **({"data": data} if draft_only else {}),
    }
