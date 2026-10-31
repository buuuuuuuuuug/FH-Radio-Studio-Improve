import argparse
import json
from test.test_voices import resource

import numpy as np
import pytest
import soundfile as sf

from backend.fh_radio_studio_cli import voice_workspace as work
from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.stingers import local_file
from backend.fh_radio_studio_cli.voices import load_plan, plan_path, prepare


def cached_originals(project, bank):
    folder = project / f"analysis/voices/original/{bank['sha256']}"
    folder.mkdir(parents=True)
    for i in range(3):
        sf.write(folder / f"{i + 1}.wav", np.full((1000, 2), 0.1 * i), 48000, subtype="PCM_16")
    return folder


def test_extract_multiple_cached_originals_is_ordered_deduplicated_and_keeps_edits(
    resource, monkeypatch
):
    project, game, source = resource
    prepared = prepare(project, game, source)
    folder = cached_originals(project, prepared["bank"])
    monkeypatch.setattr(
        work, "_run", lambda _: pytest.fail("cached audio must not be decoded again")
    )
    bank_id = prepared["bank"]["id"]
    before = source.read_bytes()
    first = work.extract_assets(
        argparse.Namespace(), project, bank_id, {"indices": [2, 0, 2], "category": "原音频/导航"}
    )
    assert first["count"] == first["added"] == 2
    assert first["reused"] == 0 and len(first["asset_ids"]) == 2
    assert [a["name"] for a in first["plan"]["assets"]] == ["条目 00001", "条目 00003"]
    for asset, index in zip(first["plan"]["assets"], [0, 2]):
        assert (
            local_file(project, asset["source"]).read_bytes()
            == (folder / f"{index + 1}.wav").read_bytes()
        )
        assert asset["origins"] == [{"bank_id": bank_id, "index": index, "name": asset["name"]}]
    edited = first["plan"]
    edited["assets"][0].update(
        name="保留名称", category="已有目录", start=0.001, end=0.01, gain_db=2
    )
    edited["banks"][bank_id]["replacements"] = {
        "1": {"asset_id": first["asset_ids"][0], "start": 0.001, "end": 0.01, "gain_db": 2}
    }
    plan_path(project).write_text(json.dumps(edited, ensure_ascii=False), encoding="utf-8")
    second = work.extract_assets(
        argparse.Namespace(), project, bank_id, {"indices": [0, 2], "category": "其他"}
    )
    assert second["added"] == 0 and second["reused"] == 2
    assert len(second["plan"]["assets"]) == 2
    assert second["plan"]["assets"][0] == edited["assets"][0]
    assert second["plan"]["banks"] == edited["banks"]
    assert source.read_bytes() == before


def test_invalid_indices_and_corrupt_preview_do_not_change_material_plan(resource):
    project, game, source = resource
    prepared = prepare(project, game, source)
    folder = cached_originals(project, prepared["bank"])
    before = plan_path(project).read_bytes()
    for indices in [[True], [0, 3], [], "all"]:
        with pytest.raises(CliError):
            work.extract_assets(
                argparse.Namespace(), project, prepared["bank"]["id"], {"indices": indices}
            )
        assert plan_path(project).read_bytes() == before
    sf.write(folder / "2.wav", np.zeros((10, 2)), 48000)
    with pytest.raises(CliError, match="缓存校验"):
        work.extract_assets(
            argparse.Namespace(), project, prepared["bank"]["id"], {"indices": [0, 1]}
        )
    assert plan_path(project).read_bytes() == before
