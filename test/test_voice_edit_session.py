import argparse
import hashlib
import io
import json
from pathlib import Path
from test.test_voices import resource
from unittest.mock import patch

import numpy as np
import soundfile as sf

from backend.fh_radio_studio_cli import material_edit, stinger_cache
from backend.fh_radio_studio_cli.voices import cmd_voices, import_assets


def test_incremental_edit_matches_full_render_and_undo_reuses_cache(tmp_path, monkeypatch):
    mono = np.linspace(-0.5, 0.5, 48000, dtype=np.float32)
    pcm = np.column_stack((mono, -mono))
    source = tmp_path / "source.wav"
    sf.write(source, pcm, 48000, subtype="FLOAT")
    asset = {"duration": 1.0, "sha256": hashlib.sha256(source.read_bytes()).hexdigest()}
    monkeypatch.setattr(
        stinger_cache, "asset_source", lambda *_a, **_k: {"path": str(source), "duration": 1.0}
    )
    ops = [{"kind": "insert", "at": 0.2, "duration": 0.1}]
    edit = {"start": 0, "end": 1, "audio_edits": ops}
    first = material_edit.material_wave(None, tmp_path, asset, edit, namespace="voices")
    calls = []
    original_apply = material_edit.apply_operations

    def apply(pcm, operations):
        calls.append(operations)
        return original_apply(pcm, operations)

    monkeypatch.setattr(material_edit, "apply_operations", apply)
    ops2 = [*ops, {"kind": "delete", "start": 0.5, "end": 0.6}]
    second = material_edit.material_wave(
        None, tmp_path, asset, {**edit, "audio_edits": ops2}, namespace="voices"
    )
    assert calls == [[ops2[-1]]]
    actual, rate = sf.read(second["path"], dtype="float32", always_2d=True)
    np.testing.assert_array_equal(actual, original_apply(pcm, ops2))
    assert rate == 48000
    assert material_edit.material_wave(None, tmp_path, asset, edit, namespace="voices") == first
    assert len(calls) == 1


def test_material_edit_rebuilds_corrupt_prefix_and_final_cache(tmp_path, monkeypatch):
    pcm = np.full((48000, 2), 0.25, dtype=np.float32)
    source = tmp_path / "source.wav"
    sf.write(source, pcm, 48000, subtype="FLOAT")
    asset = {"duration": 1.0, "sha256": hashlib.sha256(source.read_bytes()).hexdigest()}
    monkeypatch.setattr(
        stinger_cache, "asset_source", lambda *_a, **_k: {"path": str(source), "duration": 1.0}
    )
    first_op = {"kind": "insert", "at": 0.2, "duration": 0.1}
    next_op = {"kind": "silence", "start": 0.5, "end": 0.6}
    edit = {"start": 0, "end": 1, "audio_edits": [first_op]}
    first = material_edit.material_wave(None, tmp_path, asset, edit, namespace="voices")
    prefix = Path(first["path"])
    prefix.write_bytes(b"interrupted or damaged cache")
    complete_edit = {**edit, "audio_edits": [first_op, next_op]}
    result = material_edit.material_wave(None, tmp_path, asset, complete_edit, namespace="voices")
    expected = material_edit.apply_operations(pcm, complete_edit["audio_edits"])
    np.testing.assert_array_equal(
        sf.read(result["path"], dtype="float32", always_2d=True)[0], expected
    )
    # Existing but invalid final outputs are derived data too, not a permanent
    # error which forces users to discard their edit history.
    Path(result["path"]).write_bytes(b"broken final output")
    rebuilt = material_edit.material_wave(None, tmp_path, asset, complete_edit, namespace="voices")
    np.testing.assert_array_equal(
        sf.read(rebuilt["path"], dtype="float32", always_2d=True)[0], expected
    )
    assert not list(tmp_path.rglob("*.tmp.wav"))


def test_voice_worker_reads_each_edit_and_recovers_after_invalid_selection(resource, monkeypatch):
    project, game, _ = resource
    audio = project / "voice.wav"
    sf.write(audio, np.ones((48000, 2), dtype=np.float32) * 0.2, 48000, subtype="FLOAT")
    asset = import_assets(project, [audio], "测试")["plan"]["assets"][0]
    monkeypatch.setattr(
        stinger_cache, "asset_source", lambda *_a, **_k: {"path": str(audio), "duration": 1.0}
    )
    requests = [
        {
            "id": 1,
            "action": "asset",
            "asset_id": asset["id"],
            "input": {
                "wave": True,
                "start": 0,
                "end": 1,
                "audio_edits": [{"kind": "insert", "at": 0.2, "duration": 0.1}],
            },
        },
        {
            "id": 2,
            "action": "asset",
            "asset_id": asset["id"],
            "input": {
                "wave": True,
                "start": 0,
                "end": 1,
                "audio_edits": [{"kind": "delete", "start": 0, "end": 1}],
            },
        },
        {
            "id": 3,
            "action": "asset",
            "asset_id": asset["id"],
            "input": {"wave": True, "start": 0, "end": 1, "audio_edits": []},
        },
    ]
    output = io.StringIO()
    args = argparse.Namespace(
        action="serve", project_dir=str(project), game_dir=str(game), input_json=None, asset_id=None
    )
    with (
        patch("sys.stdin", io.StringIO("\n".join(map(json.dumps, requests)))),
        patch("sys.stdout", output),
    ):
        assert cmd_voices(args) == 0
    replies = list(map(json.loads, output.getvalue().splitlines()))
    assert replies[0]["result"]["duration"] == 1.1
    assert "不能删除整段" in replies[1]["error"]
    assert replies[2]["result"]["duration"] == 1
