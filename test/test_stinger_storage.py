import copy
import hashlib
import json

import pytest

from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.stinger_storage import organize_sources
from backend.fh_radio_studio_cli.stingers import load_plan, plan_path


def create(project):
    source = project / ".fh-radio-studio/stingers/sources/test.wav"
    source.parent.mkdir(parents=True)
    source.write_bytes(b"verified-test-audio")
    plan = {
        "schema_version": 1,
        "assets": [
            {
                "id": "a",
                "name": "Test",
                "source": "fh-project:/.fh-radio-studio/stingers/sources/test.wav",
                "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
            }
        ],
        "assignments": {"R9:JP:1": {"asset_id": "a"}},
        "baselines": {},
    }
    plan_path(project).write_text(json.dumps(plan), encoding="utf-8")
    return source, plan


def test_storage_migration_preserves_audio_draft_and_is_idempotent(tmp_path):
    source, before = create(tmp_path)
    assert organize_sources(tmp_path)["moved"] == 1
    after = load_plan(tmp_path)
    expected = copy.deepcopy(before)
    expected["assets"][0]["source"] = "fh-project:/sources/stingers/test.wav"
    assert after == expected
    assert (tmp_path / "sources/stingers/test.wav").read_bytes() == b"verified-test-audio"
    assert not source.exists()
    assert organize_sources(tmp_path)["moved"] == 0


def test_damaged_source_preserves_original_plan(tmp_path):
    source, before = create(tmp_path)
    source.write_bytes(b"damaged")
    with pytest.raises(CliError, match="校验失败"):
        organize_sources(tmp_path)
    assert load_plan(tmp_path) == before
    assert source.exists()


def test_conflicting_destination_preserves_source_and_plan(tmp_path):
    source, before = create(tmp_path)
    target = tmp_path / "sources/stingers/test.wav"
    target.parent.mkdir(parents=True)
    target.write_bytes(b"different")
    with pytest.raises(CliError, match="名称冲突"):
        organize_sources(tmp_path)
    assert load_plan(tmp_path) == before
    assert source.exists() and target.read_bytes() == b"different"
