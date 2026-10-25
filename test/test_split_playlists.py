"""Independent scene lists still share a single sound bank for each station."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from types import SimpleNamespace
from xml.etree import ElementTree as ET

import pytest

from backend.fh_radio_studio_cli import package
from backend.fh_radio_studio_cli.bank_expansion import (
    _find,
    _read_stbl,
    rebuild_expanded_bank,
    sound_hash,
    validate_expanded_bank_bytes,
)
from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.radio_xml import patch_package_xml_tree
from backend.fh_radio_studio_cli.reconstruct_plan import _read_radio_info_playlists

from .test_bank_expansion import bank, fsb


def station_tree():
    root = ET.Element("RadioInfo")
    stations = ET.SubElement(root, "RadioStations")
    station = ET.SubElement(stations, "RadioStation", Number="9", Name="Horizon Wave")
    tracks = ET.SubElement(station, "SampleList", Type="Track")
    for index in range(22):
        ET.SubElement(tracks, "Sample", SoundName=f"base{index:02}")
    for kind in ("FreeRoam", "Event"):
        playlist = ET.SubElement(station, "PlayList", Type=kind)
        for index in range(22):
            ET.SubElement(playlist, "Entry", Name=f"base{index:02}")
    return ET.ElementTree(root)


def plan_groups(tmp_path, *, shared=False):
    assignments = []
    for kind in ("FreeRoam", "Event"):
        for index in range(22):
            source = tmp_path / f"{'Shared' if shared else kind}-{index:02}.wav"
            source.write_bytes(b"prepared-wave")
            assignments.append(
                {
                    "source": str(source),
                    "radio_code": "R9",
                    "playlist_type": kind,
                    "slot": 22 - index,
                }
            )
    path = tmp_path / "split-plan.json"
    path.write_text(json.dumps({"assignments": assignments}), encoding="utf-8")
    groups = package.load_playlist_plan_groups(str(path), station_tree().getroot())
    return groups[0]


@pytest.mark.parametrize("allow_truncate", [False, True])
def test_split_union_cannot_truncate_one_scene(tmp_path, monkeypatch, allow_truncate):
    group = plan_groups(tmp_path)
    args = argparse.Namespace(
        bank=None, baseline_manifest=None, expand_slots=False, allow_truncate=allow_truncate
    )
    monkeypatch.setattr(package, "validate_language_settings", lambda *a: None)
    monkeypatch.setattr(package, "resolve_target_bank_for_station", lambda *a: tmp_path / "r9.bank")
    monkeypatch.setattr(package, "parse_fsb5", lambda *a: SimpleNamespace(num_samples=22))
    monkeypatch.setattr(
        package, "target_names_for_bank", lambda *a: [f"base{i:02}" for i in range(22)]
    )
    with pytest.raises(CliError, match="合计需要 44.*只有 22"):
        package.preflight_build_package_from_plan(
            args, tmp_path, tmp_path, station_tree().getroot(), [group]
        )


def test_shared22_fit_without_expansion(tmp_path):
    group = plan_groups(tmp_path, shared=True)
    assert len(group["sources"]) == 22
    package.validate_shared_bank_capacity(
        9, group["sources"], group["playlist_types_by_source"], 22, False
    )


@pytest.mark.parametrize("kind", ["FreeRoam", "Event"])
def test_real_bank_cannot_preserve_missing_scene_by_xml_alone(tmp_path, monkeypatch, kind):
    group = plan_groups(tmp_path, shared=True)
    group["playlist_types_by_source"] = {key: [kind] for key in group["playlist_types_by_source"]}
    args = argparse.Namespace(
        bank=None, baseline_manifest=None, expand_slots=True, allow_truncate=False, skip_bank=False
    )
    monkeypatch.setattr(package, "validate_language_settings", lambda *a: None)
    monkeypatch.setattr(package, "resolve_target_bank_for_station", lambda *a: tmp_path / "r9.bank")
    monkeypatch.setattr(package, "parse_fsb5", lambda *a: SimpleNamespace(num_samples=22))
    monkeypatch.setattr(
        package, "target_names_for_bank", lambda *a: [f"base{i:02}" for i in range(22)]
    )
    with pytest.raises(CliError, match="不支持只替换一个场景"):
        package.preflight_build_package_from_plan(
            args, tmp_path, tmp_path, station_tree().getroot(), [group]
        )
    with pytest.raises(CliError, match="不支持只替换一个场景"):
        package.build_radio_package_unit(
            args,
            tmp_path,
            tmp_path,
            station_tree().getroot(),
            9,
            group["sources"],
            group["playlist_types_by_source"],
            group["playlist_slots_by_source"],
            tmp_path / "prepared",
            tmp_path / "stage",
            tmp_path / "encoded",
            tmp_path / "banks",
            None,
            None,
            {},
        )
    # XML-only tooling keeps its established single-scene patch semantics.
    args.skip_bank = True
    package.preflight_build_package_from_plan(
        args, tmp_path, tmp_path, station_tree().getroot(), [group]
    )


def test_expanded44_bank_indexes_every_scene_sound(tmp_path):
    baseline_names = [f"HZ6_R9_{index:02}" for index in range(22)]
    new_names = [f"HZ6_CUSTOM_R9_{index:02}" for index in range(22)]
    original = tmp_path / "original.bank"
    original.write_bytes(bank(baseline_names))
    # FSBank may reorder samples; the shared STBL must follow encoded order.
    packed = list(reversed(baseline_names + new_names))
    rebuilt = tmp_path / "expanded44.bank"
    stats = rebuild_expanded_bank(original, fsb(44, names=True), packed, 22, rebuilt)
    raw = rebuilt.read_bytes()
    validate_expanded_bank_bytes(raw, packed)
    _, start, end = _find(raw, b"STBL")
    table = _read_stbl(raw[start:end])
    assert stats["expanded_slots"] == 22
    assert len(table) == 44
    assert [table[sound_hash(name)] for name in packed] == list(range(44))


def test_expanded_union44_writes_two_disjoint22_scene_lists(tmp_path, monkeypatch):
    tree = station_tree()
    group = plan_groups(tmp_path)
    assert len(group["sources"]) == 44
    bank = tmp_path / "R9_Tracks_CU1.assets.bank"
    args = argparse.Namespace(
        bank=None,
        baseline_manifest=None,
        expand_slots=True,
        allow_truncate=False,
        skip_bank=True,
        out_dir=str(tmp_path / "out"),
    )
    monkeypatch.setattr(package, "validate_language_settings", lambda *a: None)
    monkeypatch.setattr(package, "resolve_target_bank_for_station", lambda *a: bank)
    monkeypatch.setattr(package, "parse_fsb5", lambda *a: SimpleNamespace(num_samples=22))
    monkeypatch.setattr(
        package, "target_names_for_bank", lambda *a: [f"base{i:02}" for i in range(22)]
    )

    def prepared(sources, *a, **kw):
        return [
            {
                "source": str(source),
                "_runtime_prepared_wav": str(source),
                "display_name": source.stem,
                "artist": "Test",
                "sample_rate": 48000,
                "sample_length": 480000,
                "markers": {"TrackDrop": 48000},
                "bpm": "120",
            }
            for source in sources
        ]

    monkeypatch.setattr(package, "prepare_music_tracks", prepared)
    package.preflight_build_package_from_plan(args, tmp_path, tmp_path, tree.getroot(), [group])
    unit = package.build_radio_package_unit(
        args,
        tmp_path,
        tmp_path,
        tree.getroot(),
        9,
        group["sources"],
        group["playlist_types_by_source"],
        group["playlist_slots_by_source"],
        tmp_path / "prepared",
        tmp_path / "stage",
        tmp_path / "encoded",
        tmp_path / "banks",
        None,
        None,
        {},
    )
    assert unit["bank_slots"] == 44
    assert unit["replaceable_slots"] == {"FreeRoam": 22, "Event": 22}
    stats = patch_package_xml_tree(tree, unit, "only")
    assert stats["missing_samples"] == 0
    assert len(tree.findall(".//SampleList[@Type='Track']/Sample")) == 44
    titles = {
        s.get("SoundName"): s.get("DisplayName")
        for s in tree.findall(".//SampleList[@Type='Track']/Sample")
    }
    names = {}
    for kind in ("FreeRoam", "Event"):
        names[kind] = [
            entry.get("Name") for entry in tree.findall(f".//PlayList[@Type='{kind}']/Entry")
        ]
        assert len(names[kind]) == 22
        assert [titles[name] for name in names[kind]] == [
            f"{kind}-{i:02}" for i in reversed(range(22))
        ]
    assert not set(names["FreeRoam"]) & set(names["Event"])
    xml = tmp_path / "RadioInfo_EN.xml"
    tree.write(xml, encoding="utf-8")
    parsed = _read_radio_info_playlists(xml)["R9"]
    assert all(track.title.startswith("FreeRoam-") for track in parsed["FreeRoam"])
    assert all(track.title.startswith("Event-") for track in parsed["Event"])


def test_explicit_empty_scene_does_not_inherit_shared_track_pool(tmp_path):
    tree = station_tree()
    station = tree.find(".//RadioStation")
    event = station.find("PlayList[@Type='Event']")
    event.clear()
    event.set("Type", "Event")
    jingles = ET.SubElement(station, "SampleList", Type="Jingle")
    ET.SubElement(jingles, "Sample", SoundName="jingle", DisplayName="Not a song")
    xml = tmp_path / "RadioInfo_EN.xml"
    tree.write(xml, encoding="utf-8")
    parsed = _read_radio_info_playlists(xml)["R9"]
    assert parsed["Event"] == []
    assert len(parsed["FreeRoam"]) == 22
    station.remove(event)
    tree.write(xml, encoding="utf-8")
    # Older files omitting a list retain their fallback, restricted to Track samples.
    parsed = _read_radio_info_playlists(xml)["R9"]
    assert len(parsed["Event"]) == 22
    assert all(track.sound_name != "jingle" for track in parsed["Event"])


@pytest.mark.parametrize("builtin", ["FreeRoam", "Event"])
def test_mixed_builtin_custom_is_rejected_before_skipping_custom(tmp_path, builtin):
    opposite = "Event" if builtin == "FreeRoam" else "FreeRoam"
    path = tmp_path / "mixed.json"
    path.write_text(
        json.dumps(
            {
                "assignments": [
                    {"radio_code": "R9", "playlist_type": opposite, "track_key": "custom"}
                ]
            }
        ),
        encoding="utf-8",
    )
    targets = [{"radio": 9, "playlist_types": [builtin]}]
    with pytest.raises(CliError, match="不支持一个场景原版"):
        package.validate_split_builtin_targets(str(path), station_tree().getroot(), targets)
    # Explicit whole-station restore still overrides stale custom assignments.
    targets[0]["playlist_types"] = ["FreeRoam", "Event"]
    package.validate_split_builtin_targets(str(path), station_tree().getroot(), targets)
