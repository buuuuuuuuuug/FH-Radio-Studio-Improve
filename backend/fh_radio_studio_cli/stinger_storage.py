"""Keep imported stingers with source media; retain project-relative references."""

import copy
from pathlib import Path

from .common import CliError
from .project_refs import project_path_or_absolute


def organize_sources(project):
    from .stingers import _copy_snapshot, _write, digest, load_plan, local_file, plan_path

    plan = load_plan(project)
    updated = copy.deepcopy(plan)
    legacy = (project / ".fh-radio-studio/stingers/sources").resolve()
    updated.pop("extra_slots", None)
    updated.pop("expansion_enabled", None)
    updated["assignments"] = {
        key: value
        for key, value in updated["assignments"].items()
        if not key.split(":")[-1].startswith("FHRS_Stinger_")
    }
    moved = []
    for asset in updated["assets"]:
        source = local_file(project, asset["source"])
        if not source.resolve().is_relative_to(legacy):
            continue
        if digest(source) != asset["sha256"]:
            raise CliError(f"台呼素材校验失败，保留原目录：{asset['name']}")
        target = project / "sources/stingers" / source.name
        _copy_snapshot(source, target)
        asset["source"] = project_path_or_absolute(project, target)
        moved.append((source, target))
    if updated != plan:
        # Publish all new references before removing any old source file.
        _write(plan_path(project), updated)
        for source, target in moved:
            if source.exists() and digest(source) == digest(target):
                source.unlink()
        if legacy.exists() and not any(legacy.iterdir()):
            legacy.rmdir()
    return {"moved": len(moved), "source_directory": "sources/stingers"}
