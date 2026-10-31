import base64
import csv
import io
import json
from pathlib import Path
from test.test_stinger_bank import bank
from test.test_voice_text_index import resources
from zipfile import ZipFile

from backend.fh_radio_studio_cli.voice_text import attach_dialogue, dialogue_stamp
from backend.fh_radio_studio_cli.voice_workspace import cached_catalogs, export_text
from backend.fh_radio_studio_cli.voices import load_plan, prepare


def setup_resource(tmp_path):
    game = resources(
        tmp_path,
        '<R><Event name="Group/voice" sub="42"/></R>',
        {
            "JP": {"Dialogue_Gameplay.str": {42: "確認"}},
            "EN": {"Dialogue_Gameplay.str": {42: "Confirm"}},
            "CHS": {"Dialogue_Gameplay.str": {42: "确认"}},
            "DE": {"Dialogue_Gameplay.str": {42: "Bestätigen"}},
        },
    )
    source = game / "media/audio/FMODBanks/VO_Test_JP.assets.bank"
    source.parent.mkdir(parents=True)
    source.write_bytes(bank(["voice_JP"]))
    project = tmp_path / "Project"
    (project / ".fh-radio-studio").mkdir(parents=True)
    return project, game, source


def test_requested_text_languages_do_not_change_bank_hash_matching(tmp_path):
    project, game, source = setup_resource(tmp_path)
    parsed = prepare(project, game, source, voice_language="EN", display_language="DE")
    entry = parsed["entries"][0]
    assert entry["content"] == "Confirm"
    assert entry["translation"] == "Bestätigen"
    assert entry["name"] == "voice_JP"
    assert (entry["content_language"], entry["translation_language"]) == ("EN", "DE")


def test_switching_languages_refreshes_saved_catalog_and_preserves_audio_edits(tmp_path):
    project, game, source = setup_resource(tmp_path)
    parsed = prepare(project, game, source)
    plan = load_plan(project)
    key = parsed["bank"]["id"]
    plan["banks"][key]["replacements"] = {"0": {"asset_id": "retained"}}
    original = source.read_bytes()
    for voice, display, expected in [
        ("EN", "DE", ("Confirm", "Bestätigen")),
        ("JP", "CHS", ("確認", "确认")),
        ("EN", "EN", ("Confirm", "Confirm")),
    ]:
        item = cached_catalogs(project, plan, game, voice_language=voice, display_language=display)[
            key
        ]
        assert (item["entries"][0]["content"], item["entries"][0]["translation"]) == expected
        assert item["bank"]["replacements"] == {"0": {"asset_id": "retained"}}
    assert source.read_bytes() == original


def test_missing_requested_language_does_not_keep_old_chinese_text(tmp_path):
    _, game, source = setup_resource(tmp_path)
    entries = [{"index": 0, "name": "voice_JP", "translation": "旧中文"}]
    attach_dialogue(
        game, source, source.read_bytes(), entries, voice_language="JP", display_language="FR"
    )
    assert entries[0]["content"] == "確認"
    assert entries[0]["translation"] == ""
    assert "显示语言" in entries[0]["text_reason"]
    assert dialogue_stamp(game, source, display_language="FR") != dialogue_stamp(game, source)


def test_exports_use_selected_languages_and_have_no_resource_column(tmp_path):
    project, game, source = setup_resource(tmp_path)
    parsed = prepare(project, game, source)
    result = export_text(
        project,
        game,
        {
            "sources": [str(source)],
            "bank_id": parsed["bank"]["id"],
            "voice_language": "EN",
            "display_language": "DE",
            "format": "xlsx",
        },
    )
    assert result["headers"] == ["序号", "条目", "语音语言", "显示语言", "时长（秒）"]
    assert result["rows"][0][2:4] == ["Confirm", "Bestätigen"]
    assert len(result["rows"][0]) == len(result["headers"])
    assert "资源文件" not in result["csv"]
    assert list(csv.reader(io.StringIO(result["csv"])))[0] == result["headers"]
    with ZipFile(io.BytesIO(base64.b64decode(result["xlsx_base64"]))) as archive:
        sheet = archive.read("xl/worksheets/sheet1.xml").decode("utf-8")
        assert "资源文件" not in sheet and "Bestätigen" in sheet
