from test.test_stinger_composition import draft
from test.test_stinger_workbench import data_for
from unittest.mock import patch

import pytest

from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.stingers import (
    _write,
    freeze_for_build,
    load_plan,
    plan_path,
    restore_draft,
)


def test_legacy_null_clear_does_not_create_a_missing_asset_assignment(draft):
    project, _, _, _, _ = draft
    clear = {"asset_id": None, "start": None, "end": None, "gain_db": None, "next_track": None}
    with patch("backend.fh_radio_studio_cli.stingers.catalog", return_value=data_for(draft)):
        restore_draft(project, project, "JP", {"assignments": {"R9:JP:a": clear}})
    assert not load_plan(project)["assignments"]


def test_missing_asset_error_names_radio_position_and_material_and_preserves_saved_plan(draft):
    project, _, _, plan, _ = draft
    before = plan_path(project).read_bytes()
    bad = {**plan["assignments"]["R9:JP:a"], "asset_id": "missing"}
    with patch("backend.fh_radio_studio_cli.stingers.catalog", return_value=data_for(draft)):
        with pytest.raises(CliError) as error:
            restore_draft(
                project,
                project,
                "JP",
                {"assignments": {"R9:JP:b": bad}, "asset_names": {"missing": "Missing Voice"}},
            )
    message = str(error.value)
    assert "R9" in message and "台呼 2" in message and "Missing Voice" in message
    assert "重新选择素材" in message
    assert plan_path(project).read_bytes() == before
