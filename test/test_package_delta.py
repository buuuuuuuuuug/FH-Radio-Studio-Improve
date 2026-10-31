import argparse
import json
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

from backend.fh_radio_studio_cli.common import CliError, md5_file
from backend.fh_radio_studio_cli.deploy import _last_applied_manifest_data
from backend.fh_radio_studio_cli.package import (
    collect_package_deploy_files,
    complete_package_from_baseline,
)
from backend.fh_radio_studio_cli.package_delta import (
    finalize_changed_files,
    prepare_radioinfo_base,
    semantic_xml,
    validate_delta_dependencies,
)


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(data, dict):
        path.write_text(json.dumps(data), encoding="utf-8")
    else:
        path.write_bytes(data)


def radioinfo():
    root = ET.Element("Radio")
    stations = ET.SubElement(root, "RadioStations")
    for radio in (2, 4, 9):
        s = ET.SubElement(stations, "RadioStation", Number=str(radio), Name=f"Station {radio}")
        banks = ET.SubElement(s, "Banks")
        ET.SubElement(banks, "Bank", Name=f"R{radio}_Tracks_CU1")
        ET.SubElement(banks, "Bank", Name=f"R{radio}_Stingers_JP")
        for kind in ("Track", "DJ", "Stinger"):
            group = ET.SubElement(s, "SampleList", Type=kind)
            ET.SubElement(
                group, "Sample", SoundName=f"{radio}-{kind}", DisplayName=f"original-{kind}"
            )
        for kind in ("FreeRoam", "Event"):
            p = ET.SubElement(s, "PlayList", Type=kind)
            ET.SubElement(p, "Entry", Name=f"{radio}-Track")
    return root


@pytest.fixture
def project(tmp_path):
    project = tmp_path / "Project"
    game = tmp_path / "Game"
    package = project / "packages/stage/package"
    write(project / ".fh-radio-studio/project.json", {"schema": 1, "path_schema": 2})
    root = radioinfo()
    for locale in ("JP", "CN"):
        write(game / f"media/audio/RadioInfo_{locale}.xml", ET.tostring(root))
        write(package / f"media/audio/RadioInfo_{locale}.xml", ET.tostring(root))
    for radio in (4, 9):
        name = f"media/audio/FMODBanks/R{radio}_Tracks_CU1.assets.bank"
        write(game / name, f"original-{radio}".encode())
        write(package / name, f"original-{radio}".encode())
    stinger = "media/audio/FMODBanks/R9_Stingers_JP.assets.bank"
    write(game / stinger, b"original-stingers")
    write(package / stinger, b"replacement-stingers")
    manifest = {
        "schema_version": 2,
        "radios": [{"radio": 4}, {"radio": 9}],
        "stingers": {"banks": [{"bank": "R9_Stingers_JP.assets.bank"}]},
    }
    write(package / "fh_radio_studio_package_manifest.json", manifest)
    args = argparse.Namespace(
        game_dir=str(game), out_dir=str(package.parent), _stinger_snapshot={"project": str(project)}
    )
    return project, game, package, manifest, args


def patch_stinger(package):
    xml = package / "media/audio/RadioInfo_JP.xml"
    tree = ET.parse(xml)
    tree.find(".//RadioStation[@Number='9']/SampleList[@Type='Stinger']/Sample").set(
        "SampleLength", "96000"
    )
    tree.write(xml, encoding="utf-8")


def finish(package, args):
    prepare_radioinfo_base(args)
    patch_stinger(package)
    finalize_changed_files(args)
    return json.loads(
        (package / "fh_radio_studio_package_manifest.json").read_text(encoding="utf-8")
    )


def paths(package):
    return {i["install_relative_path"] for i in collect_package_deploy_files(package)}


def test_only_changed_stinger_and_shared_xml_are_published(project):
    _, game, package, _, args = project
    result = finish(package, args)
    assert paths(package) == {
        "media/audio/FMODBanks/R9_Stingers_JP.assets.bank",
        "media/audio/RadioInfo_JP.xml",
    }
    assert result["package_delta"]["bank_count"] == 1
    assert len(result["package_delta"]["bank_dependencies"]) == 2
    validate_delta_dependencies(result, game)
    assert {i["install_relative_path"] for i in result["package_files"]} == paths(package)


def test_live_dj_other_stations_and_stinger_banks_are_preserved(project):
    _, game, package, manifest, args = project
    manifest["radios"] = [{"radio": 9}]
    write(package / "fh_radio_studio_package_manifest.json", manifest)
    xml = game / "media/audio/RadioInfo_JP.xml"
    tree = ET.parse(xml)
    other = tree.find(".//RadioStation[@Number='2']")
    other.set("Name", "My station")
    other.find("SampleList[@Type='Track']/Sample").set("DisplayName", "my-song")
    tree.find(".//RadioStation[@Number='9']/SampleList[@Type='DJ']/Sample").set(
        "DisplayName", "my-dj"
    )
    tree.find(".//RadioStation[@Number='9']/Banks/Bank[@Name='R9_Stingers_JP']").set(
        "Custom", "keep"
    )
    tree.write(xml, encoding="utf-8")
    expected = semantic_xml(other)
    # A stale bank from a previous whole package is not a new restore request.
    write(package / "media/audio/FMODBanks/R2_Tracks_CU1.assets.bank", b"stale-original")
    result = finish(package, args)
    built = ET.parse(package / "media/audio/RadioInfo_JP.xml")
    assert semantic_xml(built.find(".//RadioStation[@Number='2']")) == expected
    assert (
        built.find(".//RadioStation[@Number='9']/SampleList[@Type='DJ']/Sample").get("DisplayName")
        == "my-dj"
    )
    assert built.find(".//Bank[@Name='R9_Stingers_JP']").get("Custom") == "keep"
    assert not any("R2_Tracks" in p for p in paths(package))
    assert any("R2_Tracks" in p for p in result["package_delta"]["excluded_unrequested_files"])


def test_requested_song_restore_is_retained_if_live_bank_is_custom(project):
    _, game, package, _, args = project
    write(game / "media/audio/FMODBanks/R4_Tracks_CU1.assets.bank", b"custom-songs")
    result = finish(package, args)
    assert "media/audio/FMODBanks/R4_Tracks_CU1.assets.bank" in paths(package)
    assert result["package_delta"]["bank_count"] == 2


def test_song_edit_keeps_its_bank_and_updates_only_music_sections(project):
    _, game, package, _, args = project
    xml = package / "media/audio/RadioInfo_JP.xml"
    tree = ET.parse(xml)
    tree.find(".//RadioStation[@Number='9']/SampleList[@Type='Track']/Sample").set(
        "DisplayName", "new-song"
    )
    tree.write(xml, encoding="utf-8")
    write(package / "media/audio/FMODBanks/R9_Tracks_CU1.assets.bank", b"new-songs")
    finish(package, args)
    assert "media/audio/FMODBanks/R9_Tracks_CU1.assets.bank" in paths(package)
    built = ET.parse(package / "media/audio/RadioInfo_JP.xml")
    assert (
        built.find(".//RadioStation[@Number='9']/SampleList[@Type='Track']/Sample").get(
            "DisplayName"
        )
        == "new-song"
    )
    assert semantic_xml(built.find(".//RadioStation[@Number='4']")) == semantic_xml(
        ET.parse(game / "media/audio/RadioInfo_JP.xml").find(".//RadioStation[@Number='4']")
    )


def test_effective_overlay_is_used_for_comparison(project):
    _, game, package, _, args = project
    shutil.copytree(game / "media", game / "mediapc")
    write(game / "media/audio/FMODBanks/R9_Tracks_CU1.assets.bank", b"shadowed-other-data")
    finish(package, args)
    assert not any("R9_Tracks" in p for p in paths(package))


@pytest.mark.parametrize("kind", ["xml", "bank"])
def test_later_game_changes_are_rejected_before_writing(project, kind):
    _, game, package, _, args = project
    result = finish(package, args)
    target = game / (
        "media/audio/RadioInfo_JP.xml"
        if kind == "xml"
        else "media/audio/FMODBanks/R4_Tracks_CU1.assets.bank"
    )
    target.write_bytes(b"changed-after-build")
    with pytest.raises(CliError, match="重新构建"):
        validate_delta_dependencies(result, game)
    assert (
        game / "media/audio/FMODBanks/R9_Stingers_JP.assets.bank"
    ).read_bytes() == b"original-stingers"


def test_repeated_deployment_accepts_already_written_xml(project):
    _, game, package, _, args = project
    result = finish(package, args)
    for item in collect_package_deploy_files(package):
        write(game / item["install_relative_path"], Path(item["source"]).read_bytes())
    validate_delta_dependencies(result, game)


def test_game_changes_during_build_keep_old_package_unpublished(project):
    _, game, package, _, args = project
    prepare_radioinfo_base(args)
    (game / "media/audio/RadioInfo_JP.xml").write_bytes(b"changed-during-build")
    with pytest.raises(CliError, match="构建期间"):
        finalize_changed_files(args)


def test_scoped_completion_does_not_copy_unrelated_baseline_files(tmp_path):
    root = tmp_path / "baseline"
    files = []
    for radio in (4, 9):
        name = f"media/audio/FMODBanks/R{radio}_Tracks_CU1.assets.bank"
        write(root / name, f"original-{radio}".encode())
        files.append(
            {
                "install_relative_path": name,
                "relative_path": f"FMODBanks/R{radio}_Tracks_CU1.assets.bank",
                "backup_path": str(root / name),
                "md5": md5_file(root / name),
            }
        )
    manifest = root / "baseline_manifest.json"
    write(manifest, {"files": files})
    package = tmp_path / "package"
    complete_package_from_baseline(package, str(manifest), scoped_radios={9})
    assert not (package / files[0]["install_relative_path"]).exists()
    assert (package / files[1]["install_relative_path"]).exists()


def test_empty_delta_is_a_valid_no_change_result(project):
    _, game, package, _, args = project
    shutil.copyfile(
        game / "media/audio/FMODBanks/R9_Stingers_JP.assets.bank",
        package / "media/audio/FMODBanks/R9_Stingers_JP.assets.bank",
    )
    prepare_radioinfo_base(args)
    finalize_changed_files(args)
    result = json.loads((package / "fh_radio_studio_package_manifest.json").read_text())
    assert result["package_delta"]["no_changes"] is True
    assert collect_package_deploy_files(package) == []


def test_partial_deploy_preserves_verified_ownership_of_untouched_files(project):
    p, game, package, _, args = project
    fingerprint = p / ".fh-radio-studio/last_applied_package_manifest.json"
    overlay = game / "mediapc/audio/FMODBanks/R2_Tracks_CU1.assets.bank"
    write(overlay, b"previous-custom-bank")
    original = {
        "install_relative_path": "mediapc/audio/FMODBanks/R2_Tracks_CU1.assets.bank",
        "md5": md5_file(overlay),
    }
    write(fingerprint, {"package_files": [original]})
    result = _last_applied_manifest_data(
        str(fingerprint),
        package_manifest_path=package / "fh_radio_studio_package_manifest.json",
        package_root=package,
        package_manifest={"package_delta": {"mode": "changed_files"}},
        game_version={},
        deploy_files=[],
        game_dir=game,
    )
    assert result["package_files"] == [original]
    overlay.write_bytes(b"external-replacement")
    result = _last_applied_manifest_data(
        str(fingerprint),
        package_manifest_path=package / "fh_radio_studio_package_manifest.json",
        package_root=package,
        package_manifest={"package_delta": {"mode": "changed_files"}},
        game_version={},
        deploy_files=[],
        game_dir=game,
    )
    assert not result["package_files"]


def test_delta_repeated_write_uses_actual_deploy_path(project):
    from backend.fh_radio_studio_cli.cli import build_parser

    p, game, package, _, args = project
    finish(package, args)
    command = build_parser().parse_args(
        [
            "deploy-package",
            str(package),
            "--game-dir",
            str(game),
            "--target-root",
            "mediapc",
            "--last-applied-manifest",
            str(p / ".fh-radio-studio/last_applied_package_manifest.json"),
            "--yes",
        ]
    )
    for _ in range(2):
        assert command.func(command) == 0
        assert (
            game / "mediapc/audio/FMODBanks/R9_Stingers_JP.assets.bank"
        ).read_bytes() == b"replacement-stingers"
        assert not (game / "mediapc/audio/FMODBanks/R4_Tracks_CU1.assets.bank").exists()
        assert not (game / "mediapc/audio/FMODBanks/R9_Tracks_CU1.assets.bank").exists()


def test_delta_rejects_changed_xml_before_actual_deploy(project):
    from backend.fh_radio_studio_cli.cli import build_parser

    _, game, package, _, args = project
    finish(package, args)
    (game / "media/audio/RadioInfo_JP.xml").write_bytes(b"changed-after-build")
    command = build_parser().parse_args(
        [
            "deploy-package",
            str(package),
            "--game-dir",
            str(game),
            "--target-root",
            "mediapc",
            "--yes",
        ]
    )
    with pytest.raises(CliError, match="重新构建"):
        command.func(command)
    assert not (game / "mediapc/audio/FMODBanks/R9_Stingers_JP.assets.bank").exists()


def test_atomic_stinger_build_compacts_before_publication(tmp_path, monkeypatch):
    from test.test_stinger_composition import draft as composition_fixture
    from test.test_stinger_composition import fake_encode, fake_render

    from backend.fh_radio_studio_cli.bank_reuse import atomic_package_build

    project, output, xml, _, args = composition_fixture.__wrapped__(tmp_path)
    game = tmp_path / "Game"
    write(game / "media/audio/RadioInfo_JP.xml", xml.read_bytes())
    write(game / "media/audio/FMODBanks/R9_Tracks_CU1.assets.bank", b"same-music")
    args.game_dir = str(game)
    monkeypatch.setattr("backend.fh_radio_studio_cli.stingers.render", fake_render)
    monkeypatch.setattr("backend.fh_radio_studio_cli.stingers._run", fake_encode)
    monkeypatch.setattr("backend.fh_radio_studio_cli.stingers._tool", lambda a, n: n)
    monkeypatch.setattr("backend.fh_radio_studio_cli.stingers._verify_audio", lambda *args: None)

    @atomic_package_build
    def build(clone):
        package = Path(clone.out_dir) / "package"
        write(package / "media/audio/RadioInfo_JP.xml", xml.read_bytes())
        write(package / "media/audio/FMODBanks/R9_Tracks_CU1.assets.bank", b"same-music")
        write(
            package / "fh_radio_studio_package_manifest.json",
            {"schema_version": 2, "radios": [{"radio": 9}]},
        )
        return 0

    assert build(args) == 0
    assert paths(output / "package") == {
        "media/audio/RadioInfo_JP.xml",
        "media/audio/FMODBanks/R9_Stingers_JP.assets.bank",
    }
