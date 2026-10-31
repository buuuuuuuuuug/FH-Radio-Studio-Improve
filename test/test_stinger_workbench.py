import argparse
import copy
import json
from test.test_stinger_composition import draft
from unittest.mock import patch

import numpy as np
import pytest
import soundfile as sf

from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.stinger_cache import cached_wave, edited_preview, warm_cache
from backend.fh_radio_studio_cli.stingers import (
    _write,
    apply_changes,
    asset_edit,
    import_audio,
    load_plan,
    plan_path,
    restore_draft,
    update_asset,
    validate_edit,
)


def data_for(draft):
    project, _, xml, plan, _ = draft
    slots = [
        {
            "id": f"R9:JP:{name}",
            "number": i + 1,
            "index": i,
            "samples": 1000,
            "duration": 1000 / 48000,
            "next_track": 500 / 48000,
        }
        for i, name in enumerate("abc")
    ]
    return {
        "locale": "JP",
        "stations": [{"key": "R9:JP", "radio": 9, "slots": slots}],
        "assets": copy.deepcopy(plan["assets"]),
    }


def test_batch_assignment_is_all_or_nothing(draft):
    project, _, _, plan, _ = draft
    before = plan_path(project).read_bytes()
    edit = plan["assignments"]["R9:JP:a"]
    with patch("backend.fh_radio_studio_cli.stingers.catalog", return_value=data_for(draft)):
        with pytest.raises(CliError):
            apply_changes(project, project, "JP", {"R9:JP:a": None, "R9:JP:b": {**edit, "end": 5}})
        assert plan_path(project).read_bytes() == before
        apply_changes(project, project, "JP", {"R9:JP:a": None, "R9:JP:b": edit})
    final = load_plan(project)
    assert "R9:JP:a" not in final["assignments"]
    assert final["assignments"]["R9:JP:b"] == edit


def test_saving_all_locales_is_atomic_and_keeps_both_languages(draft):
    project, _, xml, plan, _ = draft
    edit = plan["assignments"]["R9:JP:a"]

    def catalog_for(project, game, language):
        data = data_for(draft)
        data["locale"] = language
        station = data["stations"][0]
        station.update(
            key=f"R9:{language}",
            bank_name=f"R9_Stingers_{language}.assets.bank",
            bank_path=str(project / ".fh-radio-studio/original.assets.bank"),
            bank_sha256=plan["baselines"]["R9:JP"]["sha256"],
            xml_path=str(xml),
        )
        for slot in station["slots"]:
            slot["id"] = slot["id"].replace(":JP:", f":{language}:")
        return data

    snapshot = {
        "all_locales": True,
        "assignments": {"R9:JP:a": edit, "R9:EN:b": edit},
        "asset_edits": {"asset": None},
        "extra_slots": {},
    }
    with patch("backend.fh_radio_studio_cli.stingers.catalog", catalog_for):
        restore_draft(project, project, "JP", snapshot)
        saved = plan_path(project).read_bytes()
        bad = {**snapshot, "assignments": {**snapshot["assignments"], "R9:EN:missing": edit}}
        with pytest.raises(CliError):
            restore_draft(project, project, "JP", bad)
    assert plan_path(project).read_bytes() == saved
    assert set(load_plan(project)["assignments"]) == {"R9:JP:a", "R9:EN:b"}


def test_saving_complete_draft_clears_the_last_assignment_of_another_locale(draft):
    project, _, _, plan, _ = draft
    plan["assignments"]["R9:EN:b"] = copy.deepcopy(plan["assignments"]["R9:JP:a"])
    _write(plan_path(project), plan)
    visited = []

    def catalog_for(project, game, language):
        visited.append(language)
        data = data_for(draft)
        data["locale"] = language
        data["stations"][0]["key"] = f"R9:{language}"
        for slot in data["stations"][0]["slots"]:
            slot["id"] = slot["id"].replace(":JP:", f":{language}:")
        return data

    with patch("backend.fh_radio_studio_cli.stingers.catalog", catalog_for):
        restore_draft(project, project, "JP", {"all_locales": True, "assignments": {}})
    assert set(visited) == {"JP", "EN"}
    assert load_plan(project)["assignments"] == {}


def test_partial_locale_save_cannot_remove_material_referenced_by_retained_locale(draft):
    project, _, _, plan, _ = draft
    plan["assignments"]["R9:EN:b"] = copy.deepcopy(plan["assignments"]["R9:JP:a"])
    _write(plan_path(project), plan)
    before = plan_path(project).read_bytes()
    with patch("backend.fh_radio_studio_cli.stingers.catalog", return_value=data_for(draft)):
        with pytest.raises(CliError, match="素材仍被台呼使用"):
            restore_draft(project, project, "JP", {"assignments": {}, "removed_assets": ["asset"]})
    assert plan_path(project).read_bytes() == before


def test_asset_edit_synchronizes_used_slots_and_undo_restores_names(draft):
    project, _, _, plan, _ = draft
    plan["assets"][0]["name"] = "Original"
    plan["assignments"]["R9:JP:b"] = copy.deepcopy(plan["assignments"]["R9:JP:a"])
    _write(plan_path(project), plan)
    old = {
        "assignments": copy.deepcopy(plan["assignments"]),
        "asset_edits": {"asset": None},
        "asset_names": {"asset": "Original"},
    }
    result = update_asset(
        project, "asset", {**asset_edit(plan["assets"][0]), "gain_db": -4, "name": "New"}
    )
    assert result["updated_assignments"] == 2
    after = load_plan(project)
    assert all(v["gain_db"] == -4 for v in after["assignments"].values())
    assert after["assets"][0]["name"] == "New"
    with patch("backend.fh_radio_studio_cli.stingers.catalog", return_value=data_for(draft)):
        restore_draft(project, project, "JP", old)
    final = load_plan(project)
    assert final["assignments"] == old["assignments"]
    assert final["assets"][0]["name"] == "Original"
    assert "edit" not in final["assets"][0]


def test_waveform_cache_reuses_data_and_invalidates_on_audio_change(tmp_path):
    wav = tmp_path / "sound.wav"
    sf.write(wav, np.ones((4800, 2)) * 0.1, 48000)
    first = cached_wave(wav)
    with patch(
        "backend.fh_radio_studio_cli.stingers._read_wave",
        side_effect=AssertionError("decoded twice"),
    ):
        assert cached_wave(wav) == first
    sf.write(wav, np.ones((9600, 2)) * 0.3, 48000)
    second = cached_wave(wav)
    assert second["duration"] == 0.2
    assert max(second["bins"]) > max(first["bins"])


def test_too_short_import_does_not_poison_the_existing_library(draft):
    project, _, _, _, _ = draft
    before = plan_path(project).read_bytes()
    sound = project / "tiny.wav"
    sf.write(sound, np.zeros((480, 2)), 48000)
    with pytest.raises(CliError):
        import_audio(project, [str(sound)])
    assert plan_path(project).read_bytes() == before


def test_import_keeps_sample_precision_and_rounded_end_cannot_overrun(draft):
    project, _, _, _, _ = draft
    sound = project / "uneven.wav"
    sf.write(sound, np.zeros((447726, 2)), 48000)
    result = import_audio(project, [str(sound)])
    asset = next(a for a in result["assets"] if a.get("name") == "uneven")
    assert asset["duration"] == 447726 / 48000
    edit = {**asset_edit(asset), "end": 9.328}
    _, samples, _ = validate_edit(load_plan(project), {}, edit)
    assert samples == 447726


@pytest.mark.parametrize("gain", [-6, 6])
def test_gain_limits_are_allowed(draft, gain):
    _, _, _, plan, _ = draft
    edit = {**plan["assignments"]["R9:JP:a"], "gain_db": gain}
    validate_edit(plan, {}, edit)


@pytest.mark.parametrize("gain", [-6.001, 6.001])
def test_gain_outside_audition_range_is_rejected(draft, gain):
    _, _, _, plan, _ = draft
    edit = {**plan["assignments"]["R9:JP:a"], "gain_db": gain}
    with pytest.raises(CliError, match="音量"):
        validate_edit(plan, {}, edit)


def test_edited_preview_repairs_an_incomplete_cached_wav(draft):
    project, _, _, plan, _ = draft
    calls = []

    def render(args, project, plan, slot, edit, output):
        calls.append(output)
        output.parent.mkdir(parents=True, exist_ok=True)
        sf.write(output, np.zeros((4800, 2)), 48000, subtype="PCM_16")

    edit = plan["assignments"]["R9:JP:a"]
    with patch("backend.fh_radio_studio_cli.stingers.render", render):
        first = edited_preview(None, project, plan, edit)
        edited_preview(None, project, plan, edit)
        assert len(calls) == 1
        calls[0].write_bytes(b"incomplete")
        repaired = edited_preview(None, project, plan, edit)
        assert len(calls) == 2
        assert repaired["duration"] == first["duration"]


def test_full_cache_reuses_every_audio_without_decoding_again(draft):
    project, _, _, plan, _ = draft
    (project / "media/audio").mkdir(parents=True)
    args = argparse.Namespace(
        game_dir=str(project), locale="JP", current_game=False, progress_jsonl=False
    )
    wav = project / "analysis/decoded.wav"
    wav.parent.mkdir(exist_ok=True)
    sf.write(wav, np.zeros((4800, 2)), 48000)
    payload = {"path": str(wav), "duration": 0.1, "bins": [0.0]}
    patches = {
        "backend.fh_radio_studio_cli.stinger_cache.catalog_key": lambda *a: "key",
        "backend.fh_radio_studio_cli.stingers.catalog": lambda *a, **kw: data_for(draft),
        "backend.fh_radio_studio_cli.stingers.original_preview": lambda *a: payload,
        "backend.fh_radio_studio_cli.stinger_cache.asset_source": lambda *a: payload,
        "backend.fh_radio_studio_cli.stinger_cache.edited_preview": lambda *a: payload,
    }
    import contextlib

    with contextlib.ExitStack() as stack:
        for target, value in patches.items():
            stack.enter_context(patch(target, value))
        first = warm_cache(args, project)
        assert first["cache"]["reused"] is False
        assert first["game_view"]["stations"][0]["slots"][0]["original_preview"]["path"] == str(wav)
        with patch(
            "backend.fh_radio_studio_cli.stingers.catalog",
            side_effect=AssertionError("catalog reread"),
        ):
            second = warm_cache(args, project)
        assert second["cache"]["reused"] is True
        # A missing derivative invalidates the full cache and is restored.
        wav.unlink()
        sf.write(wav, np.zeros((9600, 2)), 48000)
        third = warm_cache(args, project)
        assert third["cache"]["reused"] is False


def test_rejected_preview_keeps_library_editable_and_does_not_cache_failure(draft):
    project, _, _, plan, _ = draft
    (project / "media/audio").mkdir(parents=True)
    args = argparse.Namespace(game_dir=str(project), locale="JP", current_game=False)
    wav = project / "analysis/decoded.wav"
    wav.parent.mkdir(exist_ok=True)
    sf.write(wav, np.zeros((4800, 2)), 48000)
    payload = {"path": str(wav), "duration": 0.1, "bins": [0.0]}
    data = data_for(draft)
    data["stations"][0]["slots"][0]["assignment"] = plan["assignments"]["R9:JP:a"]
    before = plan_path(project).read_bytes()
    with (
        patch("backend.fh_radio_studio_cli.stinger_cache.catalog_key", return_value="key"),
        patch(
            "backend.fh_radio_studio_cli.stingers.catalog",
            side_effect=lambda *a, **kw: copy.deepcopy(data),
        ),
        patch("backend.fh_radio_studio_cli.stingers.original_preview", return_value=payload),
        patch("backend.fh_radio_studio_cli.stinger_cache.asset_source", return_value=payload),
        patch(
            "backend.fh_radio_studio_cli.stinger_cache.edited_preview",
            side_effect=CliError("音量过高"),
        ),
    ):
        result = warm_cache(args, project)
    assert len(result["stations"][0]["slots"]) == 3
    assert result["assets"][0]["source_preview"] == payload
    assert result["assets"][0]["preview_error"] == "音量过高"
    assert "preview" not in result["assets"][0]
    assert result["preview_warnings"][0].startswith("R9 · 台呼 1：")
    assert len(result["preview_warnings"]) == 2
    assert not (project / "analysis/stingers/cache/JP-0.json").exists()
    assert plan_path(project).read_bytes() == before
