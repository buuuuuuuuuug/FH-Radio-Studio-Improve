import argparse
import copy
import hashlib
import json
from pathlib import Path
from test.test_stinger_bank import bank, fsb

import numpy as np
import pytest
import soundfile as sf

from backend.fh_radio_studio_cli.baseline import collect_game_baseline_file_specs
from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.stingers import local_file
from backend.fh_radio_studio_cli.voice_bank import read_bank, replace_indices
from backend.fh_radio_studio_cli.voices import (
    freeze_for_build,
    import_assets,
    load_plan,
    prepare,
    save,
    scan,
)


@pytest.fixture
def resource(tmp_path):
    project, game = tmp_path / "Project", tmp_path / "Game"
    marker = project / ".fh-radio-studio/project.json"
    marker.parent.mkdir(parents=True)
    marker.write_text("{}")
    source = game / "media/audio/FMODBanks/VO_Test_JP.assets.bank"
    source.parent.mkdir(parents=True)
    source.write_bytes(bank(["a", "b", "c"]))
    return project, game, source


def test_fixed_index_replacement_preserves_other_equal_length_entries():
    raw = bank(["a", "b", "c"])
    output = replace_indices(raw, {1: fsb(1, samples=1000, payload=91, with_cues=False)})
    info, records, blobs, lookup = read_bank(raw)
    final, final_records, final_blobs, final_lookup = read_bank(output)
    assert final.num_samples == info.num_samples == 3
    assert final_lookup == lookup
    assert blobs[0] == final_blobs[0] and blobs[2] == final_blobs[2]
    assert blobs[1] != final_blobs[1]
    assert records[1][1][4] == final_records[1][1][4]


@pytest.mark.parametrize("samples", [999, 1001])
def test_voice_replacement_accepts_changed_duration_without_remapping(samples):
    original = bank(["a", "b"])
    output = replace_indices(original, {0: fsb(1, samples=samples, with_cues=False)})
    info, _, blobs, lookup = read_bank(original)
    final, _, final_blobs, final_lookup = read_bank(output)
    assert final.samples[0].sample_count == samples
    assert final.samples[1].sample_count == info.samples[1].sample_count
    assert final_lookup == lookup and final_blobs[1] == blobs[1]


def test_prepare_backs_up_before_edit_and_reuses_immutable_original(resource):
    project, game, source = resource
    original = source.read_bytes()
    data = prepare(project, game, source)
    assert data["bank"]["supported"] is True
    assert len(data["entries"]) == 3
    backup = next((project / ".fh-radio-studio/voices/baselines").glob("*.bank"))
    assert backup.read_bytes() == original
    source.write_bytes(b"changed in game")
    assert prepare(project, game, source)["bank"] == data["bank"]
    assert backup.read_bytes() == original


def test_missing_catalog_is_rebuilt_from_pinned_original_after_live_bank_changes(resource):
    project, game, source = resource
    prepared = prepare(project, game, source)
    bank_id = prepared["bank"]["id"]
    plan_file = project / ".fh-radio-studio/voices.json"
    plan = load_plan(project)
    plan["banks"][bank_id].update(custom=True, import_path=str(source))
    plan["banks"][bank_id]["replacements"] = {"1": {"asset_id": "unchanged-reference"}}
    plan_file.write_text(json.dumps(plan), encoding="utf-8")
    catalog = project / f"analysis/voices/catalog/{prepared['bank']['sha256']}.json"
    catalog.unlink()
    source.write_bytes(bank(["different-order", "new-entry"]))
    original_snapshot = local_file(project, prepared["bank"]["source"])
    original = original_snapshot.read_bytes()
    rebuilt = prepare(project, game, source)
    assert rebuilt["bank"]["sha256"] == prepared["bank"]["sha256"]
    assert len(rebuilt["entries"]) == 3
    assert [e["name"] for e in rebuilt["entries"]] == [e["name"] for e in prepared["entries"]]
    assert rebuilt["bank"]["replacements"] == {"1": {"asset_id": "unchanged-reference"}}
    assert rebuilt["bank"]["custom"] is True
    assert rebuilt["bank"]["import_path"] == str(source)
    assert original_snapshot.read_bytes() == original


def test_variable_duration_preserves_in_range_cues_and_rejects_truncated_cues():
    raw = bank(["a", "b"])
    output = replace_indices(raw, {0: fsb(1, samples=1800, with_cues=False)})
    _, records, _, _ = read_bank(output)
    from backend.fh_radio_studio_cli.stinger_bank import cue_points

    assert cue_points(records[0][1][4]) == {"StartNextTrack": 500, "End": 1799}
    with pytest.raises(CliError, match="定位标记"):
        replace_indices(raw, {0: fsb(1, samples=400, with_cues=False)})


def test_scanning_prefers_overlay_and_groups_without_decoding(resource):
    project, game, source = resource
    overlay = game / "mediapc/audio/FMODBanks" / source.name
    overlay.parent.mkdir(parents=True)
    overlay.write_bytes(b"overlay")
    data = scan(project, game)
    assert len(data["files"]) == 1
    assert data["files"][0]["path"] == str(overlay)
    assert data["files"][0]["category"] == "无法解析／控制文件"


def test_unsupported_resource_is_backed_up_and_explained(resource):
    project, game, source = resource
    source.write_bytes(b"unsupported format")
    data = prepare(project, game, source)
    assert data["bank"]["supported"] is False
    assert data["bank"]["reason"]
    assert list((project / ".fh-radio-studio/voices/baselines").glob("*.bank"))


def test_save_validates_every_entry_before_publishing(resource):
    project, game, source = resource
    data = prepare(project, game, source)
    material = project / "input.wav"
    sf.write(material, np.zeros((4800, 1)), 48000)
    plan = import_assets(project, [material], "播报")["plan"]
    asset = plan["assets"][0]
    assert asset["source"].startswith("fh-project:/sources/voices/")
    edit = {"asset_id": asset["id"], "start": 0, "end": asset["duration"], "gain_db": 0}
    bank_id = data["bank"]["id"]
    save(project, {bank_id: {"0": edit}})
    before = load_plan(project)
    with pytest.raises(CliError, match="编号"):
        save(project, {bank_id: {"0": edit, "9": edit}})
    assert load_plan(project) == before
    save(project, {bank_id: {"0": edit, "2": edit}})
    assert len(load_plan(project)["banks"][bank_id]["replacements"]) == 2


def test_voice_targets_normalize_legacy_indices_and_reject_alias_collisions(resource):
    project, game, source = resource
    prepared = prepare(project, game, source)
    material = project / "input.wav"
    sf.write(material, np.zeros((4800, 2)), 48000)
    asset = import_assets(project, [material], "播报")["plan"]["assets"][0]
    edit = {"asset_id": asset["id"], "start": 0, "end": 0.1, "gain_db": 0}
    bank_id = prepared["bank"]["id"]
    save(project, {bank_id: {"01": edit}})
    before = load_plan(project)
    assert set(before["banks"][bank_id]["replacements"]) == {"1"}
    with pytest.raises(CliError, match="同一条目"):
        save(project, {bank_id: {"1": edit, "01": edit}})
    assert load_plan(project) == before


@pytest.mark.parametrize("damage", ["missing", "changed"])
def test_voice_build_rejects_missing_or_changed_used_source_before_encoding(resource, damage):
    project, game, source = resource
    prepared = prepare(project, game, source)
    material = project / "input.wav"
    sf.write(material, np.zeros((4800, 2)), 48000)
    asset = import_assets(project, [material], "播报")["plan"]["assets"][0]
    save(project, {prepared["bank"]["id"]: {"0": {"asset_id": asset["id"], "end": 0.1}}})
    snapshot = local_file(project, asset["source"])
    if damage == "missing":
        snapshot.unlink()
    else:
        snapshot.write_bytes(b"changed source")
    saved = (project / ".fh-radio-studio/voices.json").read_bytes()
    with pytest.raises(CliError) as error:
        freeze_for_build(argparse.Namespace(stinger_project=str(project), game_dir=str(game)))
    assert source.name in str(error.value) and "条目 1" in str(error.value)
    assert "input" in str(error.value) and "旧准备包已保留" in str(error.value)
    assert (project / ".fh-radio-studio/voices.json").read_bytes() == saved
    assert not (project / "packages").exists()


def test_voice_build_checks_a_shared_material_only_once(resource, monkeypatch):
    from backend.fh_radio_studio_cli import voices

    project, game, source = resource
    prepared = prepare(project, game, source)
    material = project / "input.wav"
    sf.write(material, np.zeros((4800, 2)), 48000)
    asset = import_assets(project, [material], "播报")["plan"]["assets"][0]
    edit = {"asset_id": asset["id"], "end": 0.1}
    save(project, {prepared["bank"]["id"]: {"0": edit, "2": edit}})
    calls = []
    original = voices.digest

    def track_digest(path):
        calls.append(path)
        return original(path)

    monkeypatch.setattr(voices, "digest", track_digest)
    frozen = freeze_for_build(argparse.Namespace(stinger_project=str(project), game_dir=str(game)))
    assert len(frozen["plan"]["banks"][prepared["bank"]["id"]]["replacements"]) == 2
    assert calls.count(local_file(project, asset["source"])) == 1


def test_legacy_index_plan_stamp_matches_the_validated_build_snapshot(resource):
    from backend.fh_radio_studio_cli.voice_workspace import plan_stamp

    project, game, source = resource
    prepared = prepare(project, game, source)
    material = project / "input.wav"
    sf.write(material, np.zeros((4800, 2)), 48000)
    asset = import_assets(project, [material], "播报")["plan"]["assets"][0]
    plan = load_plan(project)
    plan["banks"][prepared["bank"]["id"]]["replacements"] = {
        "01": {"asset_id": asset["id"], "end": 0.1}
    }
    (project / ".fh-radio-studio/voices.json").write_text(json.dumps(plan), encoding="utf-8")
    frozen = freeze_for_build(argparse.Namespace(stinger_project=str(project), game_dir=str(game)))
    assert set(frozen["plan"]["banks"][prepared["bank"]["id"]]["replacements"]) == {"1"}
    assert plan_stamp(frozen["plan"]) == plan_stamp(load_plan(project))


def test_new_baseline_inventory_includes_original_stinger_banks(resource):
    _, game, _ = resource
    stinger = game / "media/audio/FMODBanks/R9_Stingers_JP.assets.bank"
    stinger.write_bytes(bank(["a", "b"]))
    specs = collect_game_baseline_file_specs(game)
    assert any(
        s["source"] == stinger
        and s["install_relative_path"] == "media/audio/FMODBanks/R9_Stingers_JP.assets.bank"
        for s in specs
    )


def test_clearing_an_owned_voice_override_builds_exact_original(resource):
    import argparse

    from backend.fh_radio_studio_cli.common import md5_file
    from backend.fh_radio_studio_cli.voices import compose_package, freeze_for_build

    project, game, source = resource
    data = prepare(project, game, source)
    relative = data["bank"]["relative_path"].replace("media/", "mediapc/", 1)
    override = game / relative
    override.parent.mkdir(parents=True)
    override.write_bytes(b"previously applied custom voice")
    (project / ".fh-radio-studio/last_applied_package_manifest.json").write_text(
        json.dumps(
            {"package_files": [{"install_relative_path": relative, "md5": md5_file(override)}]}
        )
    )
    args = argparse.Namespace(
        stinger_project=str(project), game_dir=str(game), out_dir=str(project / "packages/test")
    )
    args._voice_snapshot = freeze_for_build(args)
    assert args._voice_snapshot["plan"]["banks"][data["bank"]["id"]]["restore"] is True
    package = Path(args.out_dir) / "package"
    package.mkdir(parents=True)
    (package / "fh_radio_studio_package_manifest.json").write_text("{}")
    compose_package(args)
    assert (package / data["bank"]["relative_path"]).read_bytes() == source.read_bytes()
    assert override.read_bytes() == b"previously applied custom voice"


def test_unowned_voice_override_is_not_silently_restored(resource):
    import argparse

    from backend.fh_radio_studio_cli.voices import freeze_for_build

    project, game, source = resource
    data = prepare(project, game, source)
    override = game / data["bank"]["relative_path"].replace("media/", "mediapc/", 1)
    override.parent.mkdir(parents=True)
    override.write_bytes(b"other modification")
    snapshot = freeze_for_build(
        argparse.Namespace(stinger_project=str(project), game_dir=str(game))
    )
    assert not any(b["restore"] or b["replacements"] for b in snapshot["plan"]["banks"].values())
