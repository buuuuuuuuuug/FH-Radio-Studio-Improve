import json
from test.test_deployment_preview import command, preview
from test.test_deployment_preview import snapshot as _snapshot

import pytest

from backend.fh_radio_studio_cli.common import CliError


def snapshot(root):
    return {k: v for k, v in _snapshot(root).items() if not k.endswith(".lock")}


from test.test_package_delta import finish, project, write

BANK = "media/audio/FMODBanks/R9_Stingers_JP.assets.bank"
XML = "media/audio/RadioInfo_JP.xml"


def setup(project, excluded):
    p, game, package, _, args = project
    finish(package, args)
    manifest_path = package / "fh_radio_studio_package_manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["language"] = {"preferred_lang": "JP"}
    write(manifest_path, manifest)
    options = [x for path in excluded for x in ("--exclude-file", path)]
    return p, game, package, command(p, game, package, extra=options)


def test_preview_keeps_rows_and_reports_incompatible_selection(project):
    _, _, _, args = setup(project, [XML])
    data = preview(args)
    assert len(data["writes"]) == 4
    assert any(XML.split("/")[-1] in issue for issue in data["selection_issues"])
    xml = next(f for f in data["writes"] if f["file_name"] == "RadioInfo_JP.xml")
    assert xml["selected"] is False


@pytest.mark.parametrize("excluded", [[XML], [BANK]])
def test_incompatible_selection_never_writes(project, excluded):
    _, game, _, args = setup(project, excluded)
    args.json, args.yes = False, True
    before = snapshot(game)
    with pytest.raises(CliError, match="同时勾选"):
        args.func(args)
    assert snapshot(game) == before


def test_settings_only_does_not_copy_skipped_resources(project):
    p, game, _, args = setup(project, [BANK, XML, "@deployment-record"])
    args.json, args.yes = False, True
    before = snapshot(game)
    assert args.func(args) == 0
    assert snapshot(game) == before
    assert (p / "UserPreferredLang").read_text(encoding="utf-8") == "JP"
    assert not (p / ".fh-radio-studio/last_applied_package_manifest.json").exists()


def test_resource_write_skips_language_and_records_only_written_files(project):
    p, game, _, args = setup(project, ["@preferred-language"])
    args.json, args.yes = False, True
    assert args.func(args) == 0
    assert not (p / "UserPreferredLang").exists()
    assert (game / BANK.replace("media/", "mediapc/", 1)).is_file()
    record = json.loads(
        (p / ".fh-radio-studio/last_applied_package_manifest.json").read_text(encoding="utf-8")
    )
    assert len(record["package_files"]) == 2


def test_empty_selection_rejected_without_writing(project):
    p, game, _, args = setup(project, [BANK, XML, "@preferred-language", "@deployment-record"])
    args.json, args.yes = False, True
    before = snapshot(p), snapshot(game)
    with pytest.raises(CliError, match="至少选择一个"):
        args.func(args)
    assert (snapshot(p), snapshot(game)) == before


def test_unknown_file_rejected_before_writing(project):
    p, game, _, args = setup(project, ["../../other-file"])
    before = snapshot(p), snapshot(game)
    with pytest.raises(CliError, match="清单已变化"):
        preview(args)
    assert (snapshot(p), snapshot(game)) == before


def test_media_preview_keeps_choices_when_one_file_needs_a_backup(project):
    p, game, _, args = setup(project, [])
    baseline = p / "baseline.json"
    data = json.loads(baseline.read_text(encoding="utf-8"))
    data["files"] = [f for f in data["files"] if f["install_relative_path"] != BANK]
    write(baseline, data)
    args.target_root = "media"
    result = preview(args)
    assert len(result["writes"]) == 4
    assert any("缺少原始备份" in issue for issue in result["selection_issues"])
    assert all(
        f["relative_path"].startswith("media/")
        for f in result["writes"]
        if f["category"] == "resource"
    )


def test_independent_voice_selection_ignores_skipped_song_dependencies(project):
    from backend.fh_radio_studio_cli.common import md5_file

    p, game, package, args = setup(
        project, [BANK, XML, "@preferred-language", "@deployment-record"]
    )
    voice = "media/audio/FMODBanks/VO_Test_JP.assets.bank"
    write(game / voice, b"original voice")
    write(package / voice, b"new voice")
    manifest_path = package / "fh_radio_studio_package_manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["voices"] = {
        "banks": [
            {
                "bank": "VO_Test_JP.assets.bank",
                "original_md5": md5_file(game / voice),
                "replaced": 1,
            }
        ]
    }
    write(manifest_path, manifest)
    song = game / "media/audio/FMODBanks/R4_Tracks_CU1.assets.bank"
    song.write_bytes(b"unrelated song change")
    assert not preview(args)["selection_issues"]
    args.json, args.yes = False, True
    assert args.func(args) == 0
    assert (game / voice.replace("media/", "mediapc/", 1)).read_bytes() == b"new voice"
    assert song.read_bytes() == b"unrelated song change"
