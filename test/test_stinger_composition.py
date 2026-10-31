import argparse
import hashlib
import json
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path
from test.test_stinger_bank import bank, fsb
from unittest.mock import patch

import numpy as np
import pytest
import soundfile as sf

from backend.fh_radio_studio_cli.bank_reuse import atomic_package_build
from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.package import package_file_fingerprints
from backend.fh_radio_studio_cli.stingers import (
    _write,
    build_base_package,
    compose_package,
    digest,
    freeze_for_build,
    plan_path,
)


@pytest.fixture
def draft(tmp_path):
    project = tmp_path / "project"
    meta = project / ".fh-radio-studio"
    meta.mkdir(parents=True)
    _write(meta / "project.json", {"schema": 1, "path_schema": 2})
    original = meta / "original.assets.bank"
    original.write_bytes(bank(["a", "b", "c"]))
    xml = meta / "RadioInfo_JP.xml"
    xml.write_text(
        """<Radio><RadioStations><RadioStation Number="9" Name="Opus">
      <SampleList Type="Track"><Sample SoundName="music" DisplayName="custom title" SampleLength="960000" /></SampleList>
      <PlayList Type="FreeRoam"><Entry Name="music" /></PlayList>
      <PlayList Type="Event"><Entry Name="music" /></PlayList>
      <SampleList Type="DJ"><Sample SoundName="dj" SampleLength="42000" /></SampleList>
      <SampleList Type="Stinger">
        <Sample SoundName="a" SampleLength="1000" SampleRate="48000"><Marker Name="StartNextTrack" Position="500"/><Marker Name="End" Position="999"/></Sample>
        <Sample SoundName="b" SampleLength="1000" SampleRate="48000"><Marker Name="StartNextTrack" Position="500"/><Marker Name="End" Position="999"/></Sample>
        <Sample SoundName="c" SampleLength="1000" SampleRate="48000"><Marker Name="StartNextTrack" Position="500"/><Marker Name="End" Position="999"/></Sample>
      </SampleList>
    </RadioStation></RadioStations></Radio>""",
        encoding="utf-8",
    )
    asset = meta / "audio.wav"
    sf.write(asset, np.zeros((4800, 2)), 48000, subtype="PCM_16")
    plan = {
        "schema_version": 1,
        "assets": [
            {
                "id": "asset",
                "source": "fh-project:/.fh-radio-studio/audio.wav",
                "duration": 0.1,
                "sha256": digest(asset),
            }
        ],
        "assignments": {
            "R9:JP:a": {
                "asset_id": "asset",
                "start": 0,
                "end": 0.1,
                "gain_db": 0,
                "next_track": 0.08,
            }
        },
        "baselines": {
            "R9:JP": {
                "radio": 9,
                "locale": "JP",
                "bank_name": "R9_Stingers_JP.assets.bank",
                "bank_ref": "fh-project:/.fh-radio-studio/original.assets.bank",
                "sha256": digest(original),
                "xml_ref": "fh-project:/.fh-radio-studio/RadioInfo_JP.xml",
                "xml_sha256": digest(xml),
            }
        },
    }
    _write(plan_path(project), plan)
    output = project / "packages" / "current"
    (output / "package/media/audio").mkdir(parents=True)
    shutil.copyfile(xml, output / "package/media/audio/RadioInfo_JP.xml")
    _write(
        output / "package/fh_radio_studio_package_manifest.json",
        {"schema_version": 2, "radios": [{"radio": 9, "marker": "keep me"}]},
    )
    args = argparse.Namespace(
        stinger_project=str(project),
        out_dir=str(output),
        quality=70,
        skip_bank=False,
        defer_publish=False,
        source=None,
        target=None,
        reuse_package=None,
    )
    args._stinger_snapshot = freeze_for_build(args)
    return project, output, xml, plan, args


def fake_render(args, project, plan, slot, edit, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    sf.write(output, np.zeros((4800, 2)), 48000, subtype="PCM_16")
    return 4800, 3840


def fake_encode(command):
    output = Path(command[command.index("-o") + 1])
    (output / "audio.fsb").write_bytes(fsb(1, samples=4800, payload=70, with_cues=False))
    return "success"


def test_shared_xml_keeps_music_dj_and_both_playlists(draft):
    project, output, original_xml, plan, args = draft
    with (
        patch("backend.fh_radio_studio_cli.stingers.render", fake_render),
        patch("backend.fh_radio_studio_cli.stingers._run", fake_encode),
        patch("backend.fh_radio_studio_cli.stingers._tool", lambda a, n: n),
        patch("backend.fh_radio_studio_cli.stingers._verify_audio"),
    ):
        compose_package(args)
    before = ET.parse(original_xml).getroot()
    after = ET.parse(output / "package/media/audio/RadioInfo_JP.xml").getroot()
    for path in [
        ".//SampleList[@Type='Track']/Sample",
        ".//SampleList[@Type='DJ']/Sample",
        ".//PlayList[@Type='FreeRoam']/Entry",
        ".//PlayList[@Type='Event']/Entry",
    ]:
        assert before.find(path).attrib == after.find(path).attrib
    target = after.find(".//Sample[@SoundName='a']")
    assert target.get("SampleLength") == "4800"
    assert target.find("Marker[@Name='StartNextTrack']").get("Position") == "3840"
    assert after.find(".//Sample[@SoundName='b']").get("SampleLength") == "1000"
    manifest = json.loads(
        (output / "package/fh_radio_studio_package_manifest.json").read_text(encoding="utf-8")
    )
    assert manifest["radios"] == [{"radio": 9, "marker": "keep me"}]
    assert manifest["stingers"]["xml_verified"]


def test_frozen_build_does_not_follow_later_draft_changes(draft):
    project, _, _, plan, args = draft
    plan["assignments"].clear()
    _write(plan_path(project), plan)
    assert "R9:JP:a" in args._stinger_snapshot["plan"]["assignments"]
    assert freeze_for_build(args)["plan"]["assignments"] == {}


def test_source_tampering_fails_before_new_stage(draft):
    project, output, _, _, args = draft
    (project / ".fh-radio-studio/audio.wav").write_bytes(b"changed")

    @atomic_package_build
    def run(clone):
        pytest.fail("must not start the build")

    with pytest.raises(CliError):
        run(args)
    assert not list(output.parent.glob(".current-building-*"))
    assert (output / "package/fh_radio_studio_package_manifest.json").exists()


def test_stinger_only_reuses_song_xml_even_after_publication_path_changes(draft):
    project, previous, xml, _, args = draft
    music = previous / "package/media/audio/FMODBanks/R9_Tracks_CU1.assets.bank"
    music.parent.mkdir()
    music.write_bytes(b"previously-built-music")
    path = previous / "package/fh_radio_studio_package_manifest.json"
    original = {
        "schema_version": 2,
        "radios": [{"radio": 9}],
        "package_files": package_file_fingerprints(previous / "package"),
    }
    for item in original["package_files"]:
        item["path"] = "old unpublished staging location"
    _write(path, original)
    args.reuse_package = str(previous)
    args.out_dir = str(project / "packages/next")
    build_base_package(args, xml.parent)
    result = Path(args.out_dir) / "package"
    assert (
        result / "media/audio/FMODBanks/R9_Tracks_CU1.assets.bank"
    ).read_bytes() == music.read_bytes()
    assert (result / "media/audio/RadioInfo_JP.xml").read_bytes() == xml.read_bytes()


def test_changed_previous_package_is_not_silently_reused(draft):
    _, previous, xml, _, args = draft
    path = previous / "package/fh_radio_studio_package_manifest.json"
    _write(path, {"package_files": package_file_fingerprints(previous / "package")})
    (previous / "package/media/audio/RadioInfo_JP.xml").write_text("<changed/>", encoding="utf-8")
    args.reuse_package = str(previous)
    args.out_dir = str(previous.parent / "other")
    with pytest.raises(CliError):
        build_base_package(args, xml.parent)


def test_reverted_stations_remove_stale_banks_and_added_xml_without_touching_songs(draft):
    project, output, original_xml, plan, args = draft
    target = output / "package/media/audio/FMODBanks/R9_Stingers_JP.assets.bank"
    target.parent.mkdir(exist_ok=True)
    target.write_bytes(b"stale-custom-bank")
    xml = output / "package/media/audio/RadioInfo_JP.xml"
    tree = ET.parse(xml)
    ET.SubElement(
        tree.find(".//SampleList[@Type='Stinger']"), "Sample", SoundName="FHRS_Stinger_R9_JP_004"
    )
    tree.write(xml, encoding="utf-8")
    plan["assignments"] = {}
    plan["extra_slots"] = {"R9:JP": 0}
    _write(plan_path(project), plan)
    args._stinger_snapshot = freeze_for_build(args)
    with patch("backend.fh_radio_studio_cli.stingers._verify_audio") as decoder:
        compose_package(args)
    assert not target.exists()
    decoder.assert_not_called()
    original, built = ET.parse(original_xml), ET.parse(xml)
    assert len(built.find(".//SampleList[@Type='Stinger']")) == 3
    for path in [".//SampleList[@Type='Track']/Sample", ".//PlayList[@Type='FreeRoam']/Entry"]:
        assert original.find(path).attrib == built.find(path).attrib
    manifest = json.loads(
        (output / "package/fh_radio_studio_package_manifest.json").read_text(encoding="utf-8")
    )
    assert manifest["stingers"]["banks"] == []
    assert manifest["stingers"]["assignment_count"] == 0


def test_cleared_stinger_still_emits_a_labelled_restore_if_custom_audio_is_in_game(draft):
    project, output, _, plan, args = draft
    game = project / "test-game"
    live = game / "media/audio/FMODBanks/R9_Stingers_JP.assets.bank"
    live.parent.mkdir(parents=True)
    live.write_bytes(b"previously-deployed-custom-audio")
    args.game_dir = str(game)
    plan["assignments"] = {}
    _write(plan_path(project), plan)
    args._stinger_snapshot = freeze_for_build(args)
    compose_package(args)
    built = output / "package/media/audio/FMODBanks/R9_Stingers_JP.assets.bank"
    assert digest(built) == plan["baselines"]["R9:JP"]["sha256"]
    manifest = json.loads(
        (output / "package/fh_radio_studio_package_manifest.json").read_text(encoding="utf-8")
    )
    assert manifest["stingers"]["banks"][0]["restored"] is True
    assert manifest["stingers"]["banks"][0]["replaced"] == 0
    assert live.read_bytes() == b"previously-deployed-custom-audio"


def test_explicit_empty_playlist_cannot_resurrect_old_custom_music(draft):
    project, previous, xml, _, args = draft
    music = previous / "package/media/audio/FMODBanks/R9_Tracks_CU1.assets.bank"
    music.parent.mkdir()
    music.write_bytes(b"obsolete-custom-music")
    args.reuse_package = str(previous)
    args.playlist_plan = {"schema_version": 2, "assignments": [], "builtin_targets": []}
    args.out_dir = str(project / "packages/empty-plan")
    build_base_package(args, xml.parent)
    root = Path(args.out_dir) / "package"
    assert not (root / "media/audio/FMODBanks/R9_Tracks_CU1.assets.bank").exists()
    manifest = json.loads(
        (root / "fh_radio_studio_package_manifest.json").read_text(encoding="utf-8")
    )
    assert manifest["assignments"] == []
    assert manifest["radios"] == []


def test_global_stinger_gain_is_frozen_and_sent_to_the_renderer(draft):
    project, output, _, _, args = draft
    args.stinger_gain_db = -3
    args._stinger_snapshot = freeze_for_build(args)
    seen = []

    def capture(render_args, *rest):
        seen.append(render_args._stinger_render_gain_db)
        return fake_render(render_args, *rest)

    with (
        patch("backend.fh_radio_studio_cli.stingers.render", capture),
        patch("backend.fh_radio_studio_cli.stingers._run", fake_encode),
        patch("backend.fh_radio_studio_cli.stingers._tool", lambda a, n: n),
        patch("backend.fh_radio_studio_cli.stingers._verify_audio"),
    ):
        compose_package(args)
    assert seen == [-3]
    manifest = json.loads(
        (output / "package/fh_radio_studio_package_manifest.json").read_text(encoding="utf-8")
    )
    assert manifest["stingers"]["gain_db"] == -3
