import argparse
import json
import struct
import zipfile
from pathlib import Path
from test.test_stinger_bank import bank
from test.test_voices import resource

import pytest

from backend.fh_radio_studio_cli import voice_workspace as work
from backend.fh_radio_studio_cli.common import CliError, md5_file
from backend.fh_radio_studio_cli.voice_text import attach_dialogue, string_values
from backend.fh_radio_studio_cli.voices import load_plan, prepare, save, scan


def string_table(values):
    blob = bytearray()
    records = bytearray()
    for key, value in values.items():
        records.extend(struct.pack("<II", key, len(blob)))
        blob.extend(value.encode("utf-8") + b"\0")
    section = struct.pack("<III", len(records) + len(blob), len(blob), len(values)) + records + blob
    header = bytearray(0x8C)
    header[:2] = b"\0\x08"
    struct.pack_into("<I", header, 0x84, 0x8C)
    return header + section


def test_voice_waveform_uses_voice_cache_and_preserves_source(resource, monkeypatch):
    from backend.fh_radio_studio_cli import stinger_cache
    from backend.fh_radio_studio_cli.voices import import_assets

    project, game, source = resource
    import numpy as np
    import soundfile as sf

    audio = project / "test-voice.wav"
    sf.write(audio, np.ones(4800, dtype=np.float32) * 0.25, 48000)
    asset = import_assets(project, [audio], "导航")["plan"]["assets"][0]
    original = (project / "sources/voices").glob("*.wav")
    original = next(original)
    before = original.read_bytes()
    calls = []

    def source_wave(args, root, item, *, namespace):
        calls.append(namespace)
        return {
            "path": str(root / "analysis" / namespace / "assets/a.wav"),
            "bins": [0.25],
            "duration": 0.1,
        }

    monkeypatch.setattr(stinger_cache, "asset_source", source_wave)
    wave = work.asset_information(argparse.Namespace(), project, asset["id"])
    assert calls == ["voices"]
    assert "analysis/voices/assets" in Path(wave["path"]).as_posix()
    assert original.read_bytes() == before
    original.write_bytes(b"changed")
    with pytest.raises(CliError, match="素材已改变"):
        work.asset_information(argparse.Namespace(), project, asset["id"])


def test_subtitles_use_exact_sound_hash_and_subtitle_id(tmp_path):
    audio = tmp_path / "media/audio"
    audio.mkdir(parents=True)
    stem = "HZ6_VO_ANNA_Test_1_SatNav"
    (audio / "DialogueScript.xml").write_text(
        f"""<DialogueScript><Trigger><!--
    WAV File : "{stem}.wav"
    Subtitle : "English script."
    --><Event name="SatNav/{stem}" sub="123" /></Trigger></DialogueScript>""",
        encoding="utf-8",
    )
    tables = tmp_path / "media/Stripped/StringTables"
    tables.mkdir(parents=True)
    for locale, value in [("JP", "左に曲がってください"), ("CHS", "请左转")]:
        with zipfile.ZipFile(tables / f"{locale}.zip", "w") as archive:
            archive.writestr("Dialogue.str", string_table({123: value}))
    entries = [{"index": 0}, {"index": 1}]
    attach_dialogue(
        tmp_path, Path("VO_SatNav_JP.assets.bank"), bank([stem + "_JP", "unrelated"]), entries
    )
    assert entries[0]["content"] == "左に曲がってください"
    assert entries[0]["translation"] == "请左转"
    assert "content" not in entries[1]
    assert string_values(b"not a table") == {}
    damaged = bytearray(string_table({123: "safe"}))
    struct.pack_into("<I", damaged, 0x8C + 16, 0xFFFFFFFF)
    assert string_values(damaged) == {}


def test_valid_bank_does_not_require_assets_in_filename(resource):
    project, game, source = resource
    renamed = source.with_name("VO_Test_JP.bank")
    renamed.write_bytes(source.read_bytes())
    result = prepare(project, game, renamed)
    assert result["bank"]["supported"] is True
    assert len(result["entries"]) == 3


def test_bulk_decode_is_reused_and_missing_outputs_resume(resource, monkeypatch):
    project, game, source = resource
    prepared = prepare(project, game, source)
    calls = []

    def decoder(command):
        calls.append(command)
        assert command[command.index("-S") + 1] == 0
        folder = Path(command[command.index("-o") + 1]).parent
        import numpy as np
        import soundfile as sf

        for i in range(3):
            entry = prepared["entries"][i]
            sf.write(
                folder / f"{i + 1}.wav",
                np.zeros((entry["samples"], entry["channels"])),
                entry["frequency"],
            )
        return ""

    monkeypatch.setattr(work, "_tool", lambda *_: "decoder")
    monkeypatch.setattr(work, "_run", decoder)
    first = work.decode_all(argparse.Namespace(), project, prepared["bank"]["id"])
    assert first["count"] == 3
    work.decode_all(argparse.Namespace(), project, prepared["bank"]["id"])
    assert len(calls) == 1
    Path(first["paths"]["1"]).unlink()
    work.decode_all(argparse.Namespace(), project, prepared["bank"]["id"])
    assert len(calls) == 2
    catalog = scan(project, game)["catalogs"][prepared["bank"]["id"]]
    assert catalog["decoded"] is True
    assert catalog["entries"][1]["preview_path"] == first["paths"]["1"]


def test_folder_tree_moves_and_renames_without_moving_source_files(resource):
    project, game, _ = resource
    plan = load_plan(project)
    plan["assets"] = [{"id": "a", "category": "导航/路线", "source": "immutable.wav"}]
    (project / ".fh-radio-studio/voices.json").write_text(json.dumps(plan))
    result = work.folders(project, {"action": "rename", "name": "导航", "target": "播报"})
    assert result["plan"]["assets"][0]["category"] == "播报/路线"
    assert result["plan"]["assets"][0]["source"] == "immutable.wav"
    with pytest.raises(CliError, match="内部"):
        work.folders(project, {"action": "rename", "name": "播报", "target": "播报/子目录"})
    with pytest.raises(CliError, match="无效"):
        work.folder_name("../outside")
    result = work.folders(project, {"action": "delete", "name": "播报"})
    assert result["plan"]["assets"][0]["category"] == "未分类"
    assert result["plan"]["assets"][0]["source"] == "immutable.wav"


def test_folder_delete_can_remove_children_and_references_without_deleting_originals(resource):
    project, game, source = resource
    prepared = prepare(project, game, source)
    plan = load_plan(project)
    original = project / "sources/voices/immutable.wav"
    original.parent.mkdir(parents=True)
    original.write_bytes(b"retained source")
    plan["assets"] = [
        {"id": "a", "category": "导航/路线", "source": str(original)},
        {"id": "b", "category": "其他", "source": "other.wav"},
    ]
    plan["folders"] = ["导航", "导航/路线", "其他"]
    plan["banks"][prepared["bank"]["id"]]["replacements"] = {
        "0": {"asset_id": "a"},
        "1": {"asset_id": "b"},
    }
    (project / ".fh-radio-studio/voices.json").write_text(json.dumps(plan), encoding="utf-8")
    result = work.folders(project, {"action": "delete", "name": "导航", "delete_assets": True})[
        "plan"
    ]
    assert [a["id"] for a in result["assets"]] == ["b"]
    assert set(result["banks"][prepared["bank"]["id"]]["replacements"]) == {"1"}
    assert result["folders"] == ["其他"]
    assert original.read_bytes() == b"retained source"


def test_separate_voice_restore_package_excludes_song_and_stinger_files(resource):
    project, game, source = resource
    data = prepare(project, game, source)
    overlay = game / data["bank"]["relative_path"].replace("media/", "mediapc/", 1)
    overlay.parent.mkdir(parents=True)
    overlay.write_bytes(b"owned override")
    (project / ".fh-radio-studio/last_applied_package_manifest.json").write_text(
        json.dumps(
            {
                "package_files": [
                    {
                        "install_relative_path": overlay.relative_to(game).as_posix(),
                        "md5": md5_file(overlay),
                    }
                ]
            }
        )
    )
    songs = project / "packages/current/keep.txt"
    songs.parent.mkdir(parents=True)
    songs.write_text("keep songs")
    result = work.build(argparse.Namespace(), project, game)
    package = Path(result["package_dir"])
    files = list((package / "media").rglob("*bank"))
    assert len(files) == 1 and files[0].name == source.name
    assert files[0].read_bytes() == source.read_bytes()
    assert songs.read_text() == "keep songs"
    manifest = json.loads((package / "fh_radio_studio_package_manifest.json").read_text())
    assert manifest["voices"]["banks"][0]["restored"] is True
    assert "stingers" not in manifest and "language" not in manifest
    preview = work.deployment(argparse.Namespace(), project, game, {})
    assert preview["resource_count"] == 1
    assert overlay.read_bytes() == b"owned override"


def test_forget_removes_only_catalog_and_keeps_original_snapshot(resource):
    project, game, source = resource
    result = prepare(project, game, source)
    bank_data = result["bank"]
    work.forget(project, bank_data["id"])
    assert bank_data["id"] not in load_plan(project)["banks"]
    assert source.exists()
    assert list((project / ".fh-radio-studio/voices/baselines").glob("*bank"))


def test_export_text_has_grouping_and_selected_columns(resource):
    project, game, source = resource
    result = work.export_text(
        project, game, {"sources": [str(source)], "fields": ["name", "duration"]}
    )
    assert result["count"] == 3
    assert source.name in result["text"]
    assert "时长（秒）" in result["text"]
    assert "中文字幕" not in result["text"]
    assert (
        work.export_text(project, game, {"sources": [str(source)], "matched_only": True})["count"]
        == 0
    )


def test_export_selected_entries_reuses_backup_catalog_when_original_path_is_gone(resource):
    project, game, source = resource
    prepared = prepare(project, game, source)
    source.unlink()
    result = work.export_text(
        project,
        game,
        {
            "sources": [str(source)],
            "bank_id": prepared["bank"]["id"],
            "indices": [1],
            "fields": ["name"],
        },
    )
    assert result["count"] == 1
    assert "\n2\t" in result["text"]
    with pytest.raises(CliError, match="有效"):
        work.export_text(
            project,
            game,
            {"sources": [str(source)], "bank_id": prepared["bank"]["id"], "indices": [999]},
        )


def test_csv_export_keeps_unicode_columns_and_quotes(resource):
    import csv
    import io

    project, game, source = resource
    parsed = prepare(project, game, source)
    catalog = project / f"analysis/voices/catalog/{parsed['bank']['sha256']}.json"
    entries = json.loads(catalog.read_text(encoding="utf-8"))
    entries[0].update(content='日本語, "引用"', translation="中文台词")
    catalog.write_text(json.dumps(entries, ensure_ascii=False), encoding="utf-8")
    result = work.export_text(
        project,
        game,
        {
            "sources": [str(source)],
            "bank_id": parsed["bank"]["id"],
            "indices": [0],
            "fields": ["content", "translation", "duration"],
        },
    )
    rows = list(csv.DictReader(io.StringIO(result["csv"])))
    assert len(rows) == 1
    assert rows[0]["语音语言"] == '日本語, "引用"'
    assert rows[0]["显示语言"] == "中文台词"
    assert "资源文件" not in rows[0]
    assert result["headers"] == ["序号", "语音语言", "显示语言", "时长（秒）"]
