import argparse
import shutil

import numpy as np
import pytest
import soundfile as sf

from backend.fh_radio_studio_cli import stingers, voices
from backend.fh_radio_studio_cli.material_edit import material_wave


def test_real_voice_and_stinger_render_preserve_edited_samples(tmp_path, monkeypatch):
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        pytest.skip("ffmpeg not available")
    source = tmp_path / "sources" / "source.wav"
    source.parent.mkdir()
    pcm = np.full((48000, 2), 0.2, dtype=np.float32)
    sf.write(source, pcm, 48000, subtype="FLOAT")
    sha = stingers.digest(source)
    asset = {"id": "a", "sha256": sha, "source": "fh-project:/sources/source.wav", "duration": 1.0}
    plan = {"assets": [asset]}
    edit = {
        "asset_id": "a",
        "start": 0,
        "end": 1,
        "gain_db": 0,
        "next_track": 0.9,
        "audio_edits": [
            {"kind": "insert", "at": 0.2, "duration": 0.1},
            {"kind": "silence", "start": 0.5, "end": 0.6},
        ],
    }
    args = argparse.Namespace(ffmpeg=ffmpeg)
    original = source.read_bytes()
    baseline = tmp_path / "baseline.wav"
    voices.render(
        args,
        tmp_path,
        plan,
        {"channels": 1, "frequency": 48000, "samples": 48000},
        {**edit, "audio_edits": []},
        baseline,
    )
    baseline_values, _ = sf.read(baseline)
    voice = tmp_path / "voice.wav"
    voices.render(
        args, tmp_path, plan, {"channels": 1, "frequency": 48000, "samples": 48000}, edit, voice
    )
    values, rate = sf.read(voice)
    assert rate == 48000 and len(values) == 52800
    assert np.max(np.abs(values[9600:14400])) == 0
    assert np.max(np.abs(values[24000:28800])) == 0
    assert values[16000] == pytest.approx(baseline_values[16000], abs=0.0001)
    stinger = tmp_path / "stinger.wav"
    samples, next_sample = stingers.render(args, tmp_path, plan, {}, edit, stinger)
    assert samples == 52800 and next_sample == 43200
    values, _ = sf.read(stinger)
    assert values.shape == (52800, 2)
    assert np.max(np.abs(values[9600:14400])) == 0
    assert np.max(np.abs(values[24000:28800])) == 0
    assert source.read_bytes() == original
    wave = material_wave(args, tmp_path, asset, edit, namespace="voices")
    before = (tmp_path / wave["path"]).stat().st_mtime_ns
    monkeypatch.setattr(
        stingers, "_run", lambda *_: pytest.fail("cached wave should not run a converter")
    )
    again = material_wave(args, tmp_path, asset, edit, namespace="voices")
    assert again["path"] == wave["path"]
    assert (tmp_path / again["path"]).stat().st_mtime_ns == before
