"""Manual race cues are optional only when a source has no Event assignment."""

import argparse
from copy import deepcopy
from types import SimpleNamespace

import pytest

from backend.fh_radio_studio_cli import package
from backend.fh_radio_studio_cli.common import CliError


@pytest.mark.parametrize("samples", [2, 48, 48000, 48000 * 300])
def test_free_roam_defaults_stay_inside_short_and_long_audio(samples):
    markers = package.free_roam_default_timing(None, samples, 48000)
    assert markers["TrackDrop"] == 0
    assert all(0 <= value < samples for value in markers.values())
    assert markers["TrackLoopStart"] < markers["TrackLoopEnd"]
    assert markers["PostRaceLoopStart"] < markers["PostRaceLoopEnd"]


@pytest.mark.parametrize("samples", [0, 1])
def test_audio_with_no_valid_loop_range_is_rejected(samples):
    with pytest.raises(CliError, match="过短"):
        package.free_roam_default_timing(None, samples, 48000)


def test_partial_saved_points_are_kept_and_not_confirmed_or_mutated():
    override = {
        "markers_sec": {"TrackDrop": 1, "TrackLoopStart": 2, "PostRaceLoopEnd": 3},
        "confirmed": {"td": False, "tl": False, "pd": False, "pl": False},
    }
    original = deepcopy(override)
    markers = package.free_roam_default_timing(override, 480000, 48000)
    assert markers["TrackDrop"] == 48000
    assert markers["TrackLoopStart"] == 96000
    assert markers["PostRaceLoopEnd"] == 144000
    assert markers["PostRaceLoopStart"] < 144000
    assert override == original


def test_invalid_saved_loop_is_not_silently_rewritten():
    with pytest.raises(CliError, match="无法组成有效循环"):
        package.free_roam_default_timing(
            {"markers_sec": {"TrackLoopStart": 3, "TrackLoopEnd": 2}}, 480000, 48000
        )


def test_free_roam_preparation_needs_no_timing_analysis(tmp_path, monkeypatch):
    source = tmp_path / "free.wav"
    source.write_bytes(b"source untouched")
    saved = {"markers_sec": {"PostDrop": 0.25}, "confirmed": {}}
    monkeypatch.setattr(package, "_metadata_cache_path_for_args", lambda args: None)
    monkeypatch.setattr(package, "_read_loudness_cache_entry", lambda *args: {"status": "ok"})
    monkeypatch.setattr(package, "_measure_loudness_cache_misses", lambda *args, **kw: {})
    monkeypatch.setattr(package, "build_custom_set_loudness_profile", lambda *args, **kw: {})
    monkeypatch.setattr(
        package,
        "prepare_loudness_matched_audio",
        lambda *args, **kw: ({}, {"sample_rate": 48000, "samples": 48000}, {}),
    )
    monkeypatch.setattr(package, "guess_metadata", lambda source: ("Artist", "Song"))
    monkeypatch.setattr(package, "_track_key_for_package_source", lambda *args: None)

    def forbid(*args, **kwargs):
        raise AssertionError("FreeRoam must not run timing analysis")

    monkeypatch.setattr(package, "estimate_timing", forbid)
    args = argparse.Namespace(bpm="0", baseline_manifest=None)
    tracks = package.prepare_music_tracks(
        [source],
        args,
        tmp_path / "stage",
        {package.source_key(source): saved},
        None,
        loudness_envelope={"ready": True},
        playlist_types_by_source={package.source_key(source): ["FreeRoam"]},
    )
    assert tracks[0]["markers"]["TrackDrop"] == 0
    assert tracks[0]["markers"]["PostDrop"] == 12000
    assert tracks[0]["markers"]["TrackLoopStart"] < tracks[0]["markers"]["TrackLoopEnd"]
    assert source.read_bytes() == b"source untouched"
    assert saved == {"markers_sec": {"PostDrop": 0.25}, "confirmed": {}}


def event_fixture(tmp_path):
    source = tmp_path / "shared.wav"
    groups = [
        {
            "radio": 1,
            "sources": [source],
            "playlist_types_by_source": {package.source_key(source): ["FreeRoam"]},
        },
        {
            "radio": 9,
            "sources": [source],
            "playlist_types_by_source": {package.source_key(source): ["Event"]},
        },
    ]
    args = argparse.Namespace(playlist_plan="-", skip_bank=False)
    override = {
        "markers_sec": {
            "TrackDrop": 0,
            "PostDrop": 4,
            "TrackLoopStart": 1,
            "TrackLoopEnd": 3,
            "PostRaceLoopStart": 4,
            "PostRaceLoopEnd": 8,
        },
        "confirmed": {"td": True, "tl": True, "pd": True, "pl": True},
    }
    return source, groups, args, override


def test_free_roam_only_does_not_require_a_timing_manifest(tmp_path):
    source, groups, args, override = event_fixture(tmp_path)
    package.validate_event_timing_overrides(args, groups[:1], {})
    # The same source's assignment in another station must enforce Event rules.
    with pytest.raises(CliError, match="已分配到比赛场景"):
        package.validate_event_timing_overrides(args, groups, {})


@pytest.mark.parametrize("change", ["unconfirmed", "missing", "nan", "inverted", "past-end"])
def test_event_needs_all_confirmed_valid_points(tmp_path, monkeypatch, change):
    source, groups, args, override = event_fixture(tmp_path)
    monkeypatch.setattr(
        package, "read_track_metadata", lambda path: SimpleNamespace(duration_sec=10)
    )
    package.validate_event_timing_overrides(args, groups, {package.source_key(source): override})
    if change == "unconfirmed":
        override["confirmed"]["pl"] = False
    elif change == "missing":
        del override["markers_sec"]["PostDrop"]
    elif change == "nan":
        override["markers_sec"]["TrackDrop"] = float("nan")
    elif change == "inverted":
        override["markers_sec"]["TrackLoopEnd"] = 0.5
    else:
        override["markers_sec"]["PostRaceLoopEnd"] = 11
    with pytest.raises(CliError):
        package.validate_event_timing_overrides(
            args, groups, {package.source_key(source): override}
        )


def test_legacy_cli_and_xml_only_keep_estimation_compatibility(tmp_path):
    source, groups, args, override = event_fixture(tmp_path)
    args.playlist_plan = None
    package.validate_event_timing_overrides(args, groups, {})
    args.playlist_plan, args.skip_bank = "-", True
    package.validate_event_timing_overrides(args, groups, {})
