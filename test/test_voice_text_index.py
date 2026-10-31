import json
import zipfile
from pathlib import Path
from test.test_stinger_bank import bank
from test.test_voice_workspace import string_table

import pytest

from backend.fh_radio_studio_cli.voice_text import attach_dialogue, subtitle_text
from backend.fh_radio_studio_cli.voice_workspace import cached_catalogs
from backend.fh_radio_studio_cli.voices import load_plan, plan_path, prepare


@pytest.mark.parametrize(
    "original, expected",
    [
        ("请[BOLD:进入嘉年华场地]。", "请进入嘉年华场地。"),
        ("[BOLD:按[A]继续]", "按[A]继续"),
        ("[BOLD:外[BOLD:内]]", "外内"),
        ("[bold:日本語] [BOLD:English]", "日本語 English"),
        ("[按键]及普通 BOLD 文本", "[按键]及普通 BOLD 文本"),
        ("没有格式标记", "没有格式标记"),
    ],
)
def test_subtitle_text_removes_only_bold_wrappers(original, expected):
    assert subtitle_text(original) == expected


def resources(tmp_path, script, tables):
    game = tmp_path / "Game"
    audio = game / "media/audio"
    audio.mkdir(parents=True)
    (audio / "Dialogue_Gameplay.xml").write_text(script, encoding="utf-8")
    folder = game / "media/Stripped/StringTables"
    folder.mkdir(parents=True)
    for locale, files in tables.items():
        with zipfile.ZipFile(folder / f"{locale}.zip", "w") as archive:
            for name, rows in files.items():
                archive.writestr(name, string_table(rows))
    return game


def test_events_without_comments_use_the_corresponding_dialogue_subtable(tmp_path):
    game = resources(
        tmp_path,
        '<R><Event name="Group/voice" sub="42"/></R>',
        {
            "JP": {"Dialogue.str": {1: "別"}, "Dialogue_Gameplay.str": {42: "元の音声"}},
            "CHS": {"Dialogue_Gameplay.str": {42: "原始语音"}},
        },
    )
    entries = [{"index": 0, "name": "untitled"}]
    attach_dialogue(
        game, Path("VO_Test_JP.assets.bank"), bank(["voice_JP"]), entries, tmp_path / "cache"
    )
    assert entries[0]["content"] == "元の音声" and entries[0]["translation"] == "原始语音"
    assert "dialogue_gameplay.str" in entries[0]["text_source"]


def test_explicit_comment_event_link_supports_a_wav_alias(tmp_path):
    script = '<R><T><!-- WAV File : "voice.WAV"\n Subtitle : "draft" --><Event name="Group/event" sub="42"/></T></R>'
    game = resources(
        tmp_path,
        script,
        {
            "JP": {"Dialogue_Gameplay.str": {42: "確認"}},
            "CHS": {"Dialogue_Gameplay.str": {42: "确认"}},
        },
    )
    entries = [{"index": 0, "name": "untitled"}]
    attach_dialogue(game, Path("VO_Test_JP.assets.bank"), bank(["voice_JP"]), entries)
    assert entries[0]["content"] == "確認" and entries[0]["translation"] == "确认"


def test_conflicting_subtables_are_not_guessed(tmp_path):
    game = resources(
        tmp_path,
        '<R><Event name="Group/voice" sub="42"/></R>',
        {
            "JP": {"Dialogue_A.str": {42: "甲"}, "Dialogue_B.str": {42: "乙"}},
            "CHS": {"Dialogue_A.str": {42: "甲"}, "Dialogue_B.str": {42: "乙"}},
        },
    )
    entries = [{"index": 0, "name": "untitled"}]
    attach_dialogue(game, Path("VO_Test_JP.assets.bank"), bank(["voice_JP"]), entries)
    assert not entries[0].get("content") and not entries[0].get("translation")
    assert entries[0]["text_reason"]


def test_old_catalogue_text_refresh_preserves_audio_and_saved_replacements(tmp_path):
    game = resources(
        tmp_path,
        '<R><Event name="Group/voice" sub="42"/></R>',
        {
            "JP": {"Dialogue_Gameplay.str": {42: "確認"}},
            "CHS": {"Dialogue_Gameplay.str": {42: "确认"}},
        },
    )
    source = game / "media/audio/FMODBanks/VO_Test_JP.assets.bank"
    source.parent.mkdir(parents=True)
    source.write_bytes(bank(["voice_JP"]))
    project = tmp_path / "Project"
    (project / ".fh-radio-studio").mkdir(parents=True)
    result = prepare(project, game, source)
    saved = load_plan(project)
    item = saved["banks"][result["bank"]["id"]]
    item.update(catalog_version=3, text_stamp="old")
    item["replacements"] = {"0": {"asset_id": "retained", "gain_db": 2}}
    plan_path(project).write_text(json.dumps(saved), encoding="utf-8")
    path = project / f"analysis/voices/catalog/{item['sha256']}.json"
    path.write_text(
        json.dumps([{**result["entries"][0], "content": "", "translation": ""}]), encoding="utf-8"
    )
    source.write_bytes(b"changed game file")
    refreshed = cached_catalogs(project, saved, game)[item["id"]]
    assert refreshed["entries"][0]["content"] == "確認"
    assert refreshed["bank"]["replacements"] == {"0": {"asset_id": "retained", "gain_db": 2}}
    assert source.read_bytes() == b"changed game file"


def test_bold_tags_are_removed_from_catalog_copy_and_export_but_game_text_is_preserved(tmp_path):
    from backend.fh_radio_studio_cli.voice_workspace import export_text

    game = resources(
        tmp_path,
        '<R><Event name="Group/voice" sub="42"/></R>',
        {
            "JP": {"Dialogue_Gameplay.str": {42: "[BOLD:確認]してください"}},
            "CHS": {"Dialogue_Gameplay.str": {42: "请[BOLD:确认]"}},
        },
    )
    archive = game / "media/Stripped/StringTables/CHS.zip"
    original_archive = archive.read_bytes()
    source = game / "media/audio/FMODBanks/VO_Test_JP.assets.bank"
    source.parent.mkdir(parents=True)
    source.write_bytes(bank(["voice_JP"]))
    project = tmp_path / "Project"
    (project / ".fh-radio-studio").mkdir(parents=True)
    parsed = prepare(project, game, source)
    entry = parsed["entries"][0]
    assert entry["content"] == "確認してください"
    assert entry["translation"] == "请确认"
    assert entry["translation_raw"] == "请[BOLD:确认]"
    exported = export_text(
        project,
        game,
        {
            "bank_id": parsed["bank"]["id"],
            "sources": [str(source)],
            "fields": ["content", "translation"],
            "indices": [0],
        },
    )
    assert "BOLD" not in exported["text"] and "BOLD" not in exported["csv"]
    assert "请确认" in exported["text"] and "確認してください" in exported["csv"]
    assert archive.read_bytes() == original_archive


def test_repeated_scans_reuse_current_text_without_reenrichment_or_plan_writes(
    tmp_path, monkeypatch
):
    import backend.fh_radio_studio_cli.voice_text as text
    from backend.fh_radio_studio_cli.voices import scan

    game = resources(
        tmp_path,
        '<R><Event name="Group/voice" sub="42"/></R>',
        {
            "JP": {"Dialogue_Gameplay.str": {42: "[BOLD:確認]"}},
            "CHS": {"Dialogue_Gameplay.str": {42: "[BOLD:确认]"}},
        },
    )
    source = game / "media/audio/FMODBanks/VO_Test_JP.assets.bank"
    source.parent.mkdir(parents=True)
    source.write_bytes(bank(["voice_JP"]))
    project = tmp_path / "Project"
    (project / ".fh-radio-studio").mkdir(parents=True)
    parsed = prepare(project, game, source)
    before = plan_path(project).read_bytes()
    catalog = project / f"analysis/voices/catalog/{parsed['bank']['sha256']}.json"
    catalog_before = catalog.read_bytes()
    monkeypatch.setattr(
        text, "attach_dialogue", lambda *a, **k: pytest.fail("Unexpected text reenrichment")
    )
    for _ in range(2):
        result = scan(project, game)
        assert result["active"]["entries"][0]["translation"] == "确认"
        assert plan_path(project).read_bytes() == before
        assert catalog.read_bytes() == catalog_before
