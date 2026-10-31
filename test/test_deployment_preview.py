import contextlib
import hashlib
import io
import json
from pathlib import Path
from test.test_package_delta import finish, project, write

import pytest

from backend.fh_radio_studio_cli.cli import build_parser
from backend.fh_radio_studio_cli.common import CliError, md5_file


def snapshot(root):
    return {
        p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in root.rglob("*")
        if p.is_file()
    }


def command(p, game, package, target="mediapc", extra=()):
    baseline = p / "baseline.json"
    write(
        baseline,
        {
            "files": [
                {
                    "install_relative_path": path.relative_to(game).as_posix(),
                    "relative_path": path.name,
                    "md5": md5_file(path),
                }
                for path in (game / "media").rglob("*")
                if path.is_file()
            ]
        },
    )
    return build_parser().parse_args(
        [
            "deploy-package",
            str(package),
            "--game-dir",
            str(game),
            "--target-root",
            target,
            "--baseline-manifest",
            str(baseline),
            "--preferred-path",
            str(p / "UserPreferredLang"),
            "--last-applied-manifest",
            str(p / ".fh-radio-studio/last_applied_package_manifest.json"),
            "--json",
            *extra,
        ]
    )


def preview(args):
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        assert args.func(args) == 0
    return json.loads(output.getvalue())


def test_preview_lists_actual_resources_settings_and_record_without_writing(project):
    p, game, package, _, args = project
    finish(package, args)
    manifest_path = package / "fh_radio_studio_package_manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["language"] = {"source_lang": "CHS", "target_lang": "JP", "preferred_lang": "JP"}
    manifest["stingers"]["banks"][0]["replaced"] = 16
    write(manifest_path, manifest)
    write(package / "media/Stripped/StringTables/JP.zip", b"display-chinese")
    operation = command(p, game, package)
    before_project, before_game = snapshot(p), snapshot(game)
    data = preview(operation)
    assert snapshot(p) == before_project and snapshot(game) == before_game
    assert data["resource_count"] == 3 and data["auxiliary_count"] == 2
    by_name = {item["file_name"]: item for item in data["writes"]}
    assert "日语" in by_name["R9_Stingers_JP.assets.bank"]["description"]
    assert "16" in by_name["R9_Stingers_JP.assets.bank"]["description"]
    assert "简体中文" in by_name["JP.zip"]["description"]
    assert by_name["UserPreferredLang"]["category"] == "setting"
    assert by_name["last_applied_package_manifest.json"]["category"] == "record"
    assert not any("Tracks_" in item["file_name"] for item in data["writes"])


@pytest.mark.parametrize("target", ["media", "mediapc"])
def test_destination_follows_selected_target(project, target):
    p, game, package, _, args = project
    finish(package, args)
    data = preview(command(p, game, package, target))
    resources = [item for item in data["writes"] if item["category"] == "resource"]
    assert all(item["relative_path"].startswith(target + "/") for item in resources)
    assert all(Path(item["destination"]).is_relative_to(game / target) for item in resources)


def test_json_and_yes_cannot_be_combined(project):
    p, game, package, _, args = project
    finish(package, args)
    operation = command(p, game, package, extra=["--yes"])
    before = snapshot(game)
    with pytest.raises(CliError, match="不能同时"):
        operation.func(operation)
    assert snapshot(game) == before


def test_owned_overlay_removal_is_previewed_without_deleting(project):
    p, game, package, _, args = project
    finish(package, args)
    overlay = game / "mediapc/audio/RadioInfo_JP.xml"
    write(overlay, (package / "media/audio/RadioInfo_JP.xml").read_bytes())
    fingerprint = p / ".fh-radio-studio/last_applied_package_manifest.json"
    write(
        fingerprint,
        {
            "package_files": [
                {
                    "install_relative_path": "mediapc/audio/RadioInfo_JP.xml",
                    "md5": md5_file(overlay),
                }
            ]
        },
    )
    data = preview(command(p, game, package, "media"))
    assert data["removals"][0]["destination"] == str(overlay)
    assert data["removals"][0]["operation"] == "remove"
    assert overlay.is_file()


def test_changed_game_configuration_stops_preview_before_any_write(project):
    p, game, package, _, args = project
    finish(package, args)
    (game / "media/audio/RadioInfo_JP.xml").write_bytes(b"changed-after-build")
    operation = command(p, game, package)
    before = snapshot(game)
    with pytest.raises(CliError, match="重新构建"):
        preview(operation)
    assert snapshot(game) == before


def test_real_restore_is_explained_as_restore_not_custom_music(project):
    p, game, package, _, args = project
    (game / "media/audio/FMODBanks/R4_Tracks_CU1.assets.bank").write_bytes(b"custom-before-restore")
    finish(package, args)
    manifest = package / "fh_radio_studio_package_manifest.json"
    data = json.loads(manifest.read_text(encoding="utf-8"))
    data["restored_radios"] = [{"radio": 4}]
    write(manifest, data)
    result = preview(command(p, game, package))
    restored = next(
        item for item in result["writes"] if item["file_name"] == "R4_Tracks_CU1.assets.bank"
    )
    assert "恢复第 4 电台的原版歌曲" in restored["description"]
