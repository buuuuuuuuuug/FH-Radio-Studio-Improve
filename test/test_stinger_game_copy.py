import argparse
from test.test_stinger_composition import draft
from test.test_stinger_workbench import data_for
from unittest.mock import patch

import numpy as np
import pytest
import soundfile as sf

from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.stinger_game_copy import copy_game
from backend.fh_radio_studio_cli.stingers import load_plan, plan_path


def test_copy_original_game_clears_draft_but_keeps_materials_and_snapshots(draft):
    project, _, _, plan, _ = draft
    data = data_for(draft)
    station = data["stations"][0]
    station["bank_name"] = plan["baselines"]["R9:JP"]["bank_name"]
    station["bank_sha256"] = plan["baselines"]["R9:JP"]["sha256"]
    with patch("backend.fh_radio_studio_cli.stingers._read_catalog", return_value=data):
        result = copy_game(argparse.Namespace(), project, project, "JP")
    final = load_plan(project)
    assert result["saved"] and not result["needs_cache"]
    assert not final["assignments"]
    assert final["assets"] == plan["assets"]
    assert final["baselines"] == plan["baselines"]


def live_custom(draft):
    data = data_for(draft)
    station = data["stations"][0]
    station["bank_name"] = draft[3]["baselines"]["R9:JP"]["bank_name"]
    station["bank_sha256"] = "changed-game-bank"
    for slot, name in zip(station["slots"], "abc"):
        slot["sound_name"] = name
    return data


def test_copy_custom_game_preserves_existing_slot_order_and_cues(draft):
    project, _, _, plan, _ = draft
    data = live_custom(draft)
    sound = project / "live.wav"
    sf.write(sound, np.ones((9600, 2)) * 0.1, 48000)
    with (
        patch("backend.fh_radio_studio_cli.stingers._read_catalog", return_value=data),
        patch(
            "backend.fh_radio_studio_cli.stingers.original_preview",
            return_value={"path": str(sound)},
        ),
    ):
        result = copy_game(argparse.Namespace(), project, project, "JP")
    final = load_plan(project)
    assert result["needs_cache"]
    assert list(final["assignments"]) == [
        "R9:JP:a",
        "R9:JP:b",
        "R9:JP:c",
    ]
    assert all(edit["end"] == 0.2 for edit in final["assignments"].values())
    assert final["baselines"] == plan["baselines"]
    assert final["assets"][0] == plan["assets"][0]


def test_copy_game_decode_failure_restores_complete_draft(draft):
    project, _, _, _, _ = draft
    before = plan_path(project).read_bytes()
    sound = project / "live.wav"
    sf.write(sound, np.ones((9600, 2)) * 0.1, 48000)
    with (
        patch(
            "backend.fh_radio_studio_cli.stingers._read_catalog", return_value=live_custom(draft)
        ),
        patch(
            "backend.fh_radio_studio_cli.stingers.original_preview",
            side_effect=[{"path": str(sound)}, CliError("test decode failure")],
        ),
    ):
        with pytest.raises(CliError, match="test decode failure"):
            copy_game(argparse.Namespace(), project, project, "JP")
    assert plan_path(project).read_bytes() == before


def test_copy_game_rejects_missing_original_slots_without_changing_draft(draft):
    project, _, _, _, _ = draft
    before = plan_path(project).read_bytes()
    data = live_custom(draft)
    data["stations"][0]["slots"].pop()
    with patch("backend.fh_radio_studio_cli.stingers._read_catalog", return_value=data):
        with pytest.raises(CliError, match="数量与原始数量不同"):
            copy_game(argparse.Namespace(), project, project, "JP")
    assert plan_path(project).read_bytes() == before


def test_copy_game_draft_does_not_save_the_proposed_arrangement(draft):
    project, _, _, plan, _ = draft
    data = live_custom(draft)
    data["stations"][0]["bank_sha256"] = plan["baselines"]["R9:JP"]["sha256"]
    with patch("backend.fh_radio_studio_cli.stingers._read_catalog", return_value=data):
        result = copy_game(argparse.Namespace(), project, project, "JP", draft_only=True)
    assert result["assignment_count"] == 0
    assert result["data"] is data
    assert load_plan(project)["assignments"] == plan["assignments"]
