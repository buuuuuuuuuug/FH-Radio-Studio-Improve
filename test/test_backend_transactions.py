from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path
from unittest.mock import patch

import pytest

from backend.fh_radio_studio_cli import (
    baseline,
    deploy,
    file_transaction,
    import_audio,
    metadata,
    migration,
)
from backend.fh_radio_studio_cli.common import CliError, load_manifest, md5_file
from backend.fh_radio_studio_cli.deployment_paths import contained_game_path
from backend.fh_radio_studio_cli.file_lock import FileLockTimeout, exclusive_file_lock
from backend.fh_radio_studio_cli.file_transaction import replace_files_atomically
from backend.fh_radio_studio_cli.timing_import import _normalized


def make_package(tmp_path):
    game, package = tmp_path / "game", tmp_path / "package"
    files = ["media/audio/RadioInfo_CN.xml", "media/audio/FMODBanks/R1_Tracks.assets.bank"]
    records = []
    for name in files:
        source, target = package / name, game / name
        source.parent.mkdir(parents=True, exist_ok=True)
        target.parent.mkdir(parents=True, exist_ok=True)
        source.write_bytes(b"custom:" + name.encode())
        target.write_bytes(b"original:" + name.encode())
        records.append(
            {"relative_path": name, "install_relative_path": name, "md5": md5_file(target)}
        )
    baseline_path = tmp_path / "baseline.json"
    baseline_path.write_text(json.dumps({"files": records}), encoding="utf-8")
    (package / "fh_radio_studio_package_manifest.json").write_text(
        json.dumps({"language": {"preferred_lang": "JP"}}), encoding="utf-8"
    )
    args = argparse.Namespace(
        game_dir=str(game),
        package_dir=str(package),
        baseline_manifest=str(baseline_path),
        last_applied_manifest=str(tmp_path / "fingerprint.json"),
        target_root="mediapc",
        preferred_path=str(tmp_path / "UserPreferredLang"),
        force=False,
        yes=True,
    )
    return args, game, package, files


def fail_one_replace(destination):
    original = os.replace
    failed = False

    def replace(source, target):
        nonlocal failed
        if not failed and Path(target) == destination and str(source).endswith(".install-tmp"):
            failed = True
            raise OSError("injected install failure")
        return original(source, target)

    return replace


def snapshot(root):
    # Persistent advisory locks have no application data and are intentionally
    # kept so concurrent requests keep locking the same inode/file.
    return {
        str(p.relative_to(root)): p.read_bytes()
        for p in root.rglob("*")
        if p.is_file() and not p.name.endswith(".lock")
    }


@pytest.mark.parametrize("target", ["media", "mediapc"])
def test_deploy_and_restore_share_the_game_write_lock(tmp_path, target):
    args, game, _, _ = make_package(tmp_path)
    args.target_root = target
    before = snapshot(tmp_path)
    with exclusive_file_lock(game / ".fh-radio-studio-write.lock"):
        with pytest.raises(CliError, match="Another operation is writing"):
            deploy.cmd_deploy_package(args)
        with pytest.raises(CliError, match="Another operation is writing"):
            baseline.cmd_baseline(
                argparse.Namespace(
                    baseline_action="apply",
                    game_dir=str(game),
                    baseline_dir=str(tmp_path / "unused"),
                    yes=True,
                )
            )
    assert snapshot(tmp_path) == before


def test_deploy_accepts_game_audio_directory_without_nesting_install_paths(tmp_path):
    args, game, package, files = make_package(tmp_path)
    args.game_dir = str(game / "media/audio")
    deploy.cmd_deploy_package(args)
    for name in files:
        assert (game / name.replace("media/", "mediapc/", 1)).read_bytes() == (
            package / name
        ).read_bytes()
    assert not (game / "media/audio/mediapc").exists()


def test_deploy_rolls_back_existing_and_new_files_with_fingerprint_and_language(tmp_path):
    args, game, _, files = make_package(tmp_path)
    language = Path(args.preferred_path)
    language.write_bytes(b"EN")
    fingerprint = Path(args.last_applied_manifest)
    fingerprint.write_text("{}", encoding="utf-8")
    overlay = game / files[0].replace("media/", "mediapc/", 1)
    overlay.parent.mkdir(parents=True, exist_ok=True)
    overlay.write_bytes((game / files[0]).read_bytes())
    os.utime(overlay, ns=(1_600_000_000_000_000_000, 1_600_000_000_000_000_000))
    mtime = overlay.stat().st_mtime_ns
    before = snapshot(tmp_path)
    with patch.object(file_transaction.os, "replace", side_effect=fail_one_replace(fingerprint)):
        with pytest.raises(OSError, match="injected"):
            deploy.cmd_deploy_package(args)
    assert snapshot(tmp_path) == before
    assert overlay.stat().st_mtime_ns == mtime


def test_deploy_copy_failure_changes_no_destinations(tmp_path):
    args, _, _, _ = make_package(tmp_path)
    before = snapshot(tmp_path)
    original = shutil.copy2
    copied = 0

    def fail_copy(source, destination):
        nonlocal copied
        copied += 1
        if copied == 2:
            raise OSError("injected copy failure")
        return original(source, destination)

    with patch.object(file_transaction.shutil, "copy2", side_effect=fail_copy):
        with pytest.raises(OSError, match="injected"):
            deploy.cmd_deploy_package(args)
    assert snapshot(tmp_path) == before


def test_failed_overlay_cleanup_rolls_back_media_and_deployment_records(tmp_path):
    args, game, _, files = make_package(tmp_path)
    deploy.cmd_deploy_package(args)
    args.target_root = "media"
    before = snapshot(tmp_path)
    overlay = game / files[0].replace("media/", "mediapc/", 1)
    original = os.replace
    failed = False

    def fail_overlay(source, destination):
        nonlocal failed
        if not failed and Path(source) == overlay:
            failed = True
            raise OSError("injected overlay cleanup failure")
        return original(source, destination)

    with patch.object(file_transaction.os, "replace", side_effect=fail_overlay):
        with pytest.raises(OSError, match="injected"):
            deploy.cmd_deploy_package(args)
    assert snapshot(tmp_path) == before


def test_changed_source_fails_staging_without_overwriting_target(tmp_path):
    source, target = tmp_path / "source", tmp_path / "target"
    source.write_bytes(b"one")
    expected = md5_file(source)
    source.write_bytes(b"two")
    target.write_bytes(b"keep")
    with pytest.raises(CliError, match="Source changed"):
        replace_files_atomically([(source, target, expected)])
    assert target.read_bytes() == b"keep"
    assert snapshot(tmp_path) == {"source": b"two", "target": b"keep"}


def test_rollback_preserves_original_readonly_file_and_metadata(tmp_path):
    source, original = tmp_path / "source", tmp_path / "original"
    second_source, second_target = tmp_path / "next-source", tmp_path / "next-target"
    source.write_bytes(b"new readonly file")
    original.write_bytes(b"original readonly file")
    second_source.write_bytes(b"next")
    os.utime(original, ns=(1_600_000_000_000_000_000, 1_600_000_000_000_000_000))
    source.chmod(stat.S_IREAD)
    original.chmod(stat.S_IREAD)
    before = original.stat()
    try:
        with patch.object(
            file_transaction.os, "replace", side_effect=fail_one_replace(second_target)
        ):
            with pytest.raises(OSError, match="injected"):
                replace_files_atomically(
                    [(source, original, None), (second_source, second_target, None)]
                )
        assert original.read_bytes() == b"original readonly file"
        assert original.stat().st_mtime_ns == before.st_mtime_ns
        assert stat.S_IMODE(original.stat().st_mode) == stat.S_IMODE(before.st_mode)
        assert not second_target.exists()
        assert not list(tmp_path.glob("*.install-*"))
    finally:
        source.chmod(stat.S_IWRITE)
        original.chmod(stat.S_IWRITE)


@pytest.mark.parametrize(
    "relative",
    ["../outside", "C:/outside", "/outside", "media/../x", "media/a:ads", "media/\x00file"],
)
def test_relative_path_rejects_unsafe_forms(tmp_path, relative):
    with pytest.raises(CliError):
        contained_game_path(tmp_path, relative)


@pytest.mark.parametrize("document", ["[]", "null", '"string"', "12", "{bad"])
def test_manifest_requires_an_object(tmp_path, document):
    manifest = tmp_path / "manifest.json"
    manifest.write_text(document, encoding="utf-8")
    with pytest.raises(CliError):
        load_manifest(manifest)


def make_baseline(tmp_path):
    game, saved = tmp_path / "game", tmp_path / "baseline"
    files = []
    for name in ["RadioInfo_CN.xml", "FMODBanks/R1_Tracks.assets.bank"]:
        relative = f"media/audio/{name}"
        source, target = saved / relative, game / relative
        source.parent.mkdir(parents=True, exist_ok=True)
        target.parent.mkdir(parents=True, exist_ok=True)
        source.write_bytes(b"original:" + name.encode())
        target.write_bytes(b"custom:" + name.encode())
        files.append(
            {"relative_path": name, "install_relative_path": relative, "md5": md5_file(source)}
        )
    manifest = saved / "baseline_manifest.json"
    manifest.write_text(json.dumps({"kind": "game_baseline", "files": files}), encoding="utf-8")
    return game, saved, files


def test_baseline_restore_checks_all_files_before_writing(tmp_path):
    game, saved, files = make_baseline(tmp_path)
    (saved / files[-1]["install_relative_path"]).write_bytes(b"corrupted")
    before = snapshot(game)
    with pytest.raises(CliError, match="MD5 mismatch"):
        baseline.cmd_baseline(
            argparse.Namespace(
                baseline_action="apply", game_dir=str(game), baseline_dir=str(saved), yes=True
            )
        )
    assert snapshot(game) == before


def test_baseline_restore_rolls_back_mid_install(tmp_path):
    game, saved, files = make_baseline(tmp_path)
    before = snapshot(game)
    with patch.object(
        file_transaction.os,
        "replace",
        side_effect=fail_one_replace(game / files[-1]["install_relative_path"]),
    ):
        with pytest.raises(OSError, match="injected"):
            baseline.cmd_baseline(
                argparse.Namespace(
                    baseline_action="apply", game_dir=str(game), baseline_dir=str(saved), yes=True
                )
            )
    assert snapshot(game) == before


def test_baseline_restore_rejects_manifest_path_escape(tmp_path):
    game, saved, files = make_baseline(tmp_path)
    files[-1]["install_relative_path"] = "../../outside"
    (saved / "baseline_manifest.json").write_text(json.dumps({"files": files}), encoding="utf-8")
    before = snapshot(tmp_path)
    with pytest.raises(CliError):
        baseline.cmd_baseline(
            argparse.Namespace(
                baseline_action="apply", game_dir=str(game), baseline_dir=str(saved), yes=True
            )
        )
    assert snapshot(tmp_path) == before


def make_overlay_restore(tmp_path):
    """Use the real default deployment flow so ownership is not fabricated."""
    game, saved, files = make_baseline(tmp_path)
    stinger = "media/audio/FMODBanks/R1_Stingers_JP.assets.bank"
    for root, data in ((saved, b"original stinger"), (game, b"previous stinger")):
        path = root / stinger
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    files.append(
        {
            "relative_path": "FMODBanks/R1_Stingers_JP.assets.bank",
            "install_relative_path": stinger,
            "md5": md5_file(saved / stinger),
        }
    )
    manifest = saved / "baseline_manifest.json"
    manifest.write_text(json.dumps({"kind": "game_baseline", "files": files}), encoding="utf-8")
    package = tmp_path / "package"
    for item in files:
        path = package / item["install_relative_path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"deployed overlay:" + path.name.encode())
    (package / "fh_radio_studio_package_manifest.json").write_text("{}", encoding="utf-8")
    fingerprint = tmp_path / "fingerprint.json"
    deploy.cmd_deploy_package(
        argparse.Namespace(
            game_dir=str(game),
            package_dir=str(package),
            target_root="mediapc",
            baseline_manifest=str(manifest),
            last_applied_manifest=str(fingerprint),
            force=False,
            yes=True,
            preferred_path=None,
        )
    )
    args = argparse.Namespace(
        baseline_action="apply",
        game_dir=str(game),
        baseline_dir=str(saved),
        last_applied_manifest=str(fingerprint),
        yes=True,
    )
    return args, game, saved, files


def test_baseline_restore_removes_only_owned_overrides_in_its_scope(tmp_path):
    args, game, saved, files = make_overlay_restore(tmp_path)
    unrelated = game / "mediapc/audio/FMODBanks/R2_Stingers_JP.assets.bank"
    unrelated.write_bytes(b"another project's resource")
    assert baseline.cmd_baseline(args) == 0
    for item in files:
        relative = item["install_relative_path"]
        assert (game / relative).read_bytes() == (saved / relative).read_bytes()
        assert not (game / relative.replace("media/", "mediapc/", 1)).exists()
    assert unrelated.read_bytes() == b"another project's resource"


@pytest.mark.parametrize("ownership", ["missing", "changed"])
def test_baseline_restore_refuses_unowned_overrides_before_any_write(tmp_path, ownership):
    args, game, _, files = make_overlay_restore(tmp_path)
    if ownership == "missing":
        args.last_applied_manifest = None
    else:
        relative = files[-1]["install_relative_path"].replace("media/", "mediapc/", 1)
        (game / relative).write_bytes(b"modified by another program")
    before = snapshot(tmp_path)
    with pytest.raises(CliError, match="not owned"):
        baseline.cmd_baseline(args)
    assert snapshot(tmp_path) == before


def test_baseline_restore_overlay_cleanup_failure_rolls_back_all_changes(tmp_path):
    args, game, _, files = make_overlay_restore(tmp_path)
    before = snapshot(tmp_path)
    overlay = game / files[-1]["install_relative_path"].replace("media/", "mediapc/", 1)
    original = file_transaction.os.replace
    failed = False

    def fail_cleanup(source, destination):
        nonlocal failed
        if not failed and Path(source) == overlay:
            failed = True
            raise OSError("injected restoration override cleanup failure")
        return original(source, destination)

    with patch.object(file_transaction.os, "replace", side_effect=fail_cleanup):
        with pytest.raises(OSError, match="injected restoration"):
            baseline.cmd_baseline(args)
    assert snapshot(tmp_path) == before


def test_baseline_restore_dry_run_keeps_media_and_owned_overrides(tmp_path):
    args, _, _, _ = make_overlay_restore(tmp_path)
    args.yes = False
    before = snapshot(tmp_path)
    assert baseline.cmd_baseline(args) == 0
    assert snapshot(tmp_path) == before


def test_promote_corrupt_pending_preserves_current(tmp_path):
    current, pending = tmp_path / "current", tmp_path / "pending"
    current.mkdir()
    pending.mkdir()
    (current / "baseline_manifest.json").write_bytes(b"valuable original")
    (pending / "baseline_manifest.json").write_bytes(b"{corrupt")
    before = snapshot(tmp_path)
    with pytest.raises(CliError):
        baseline.cmd_baseline(
            argparse.Namespace(
                baseline_action="promote",
                current_dir=str(current),
                pending_dir=str(pending),
                target_current_dir=None,
                yes=True,
            )
        )
    assert snapshot(tmp_path) == before


def test_promote_manifest_write_failure_restores_both_baselines(tmp_path):
    _, pending, _ = make_baseline(tmp_path)
    current = tmp_path / "current"
    current.mkdir()
    (current / "baseline_manifest.json").write_bytes(b"valuable original")
    before = snapshot(tmp_path)
    with patch.object(
        baseline, "write_project_json", side_effect=OSError("injected manifest failure")
    ):
        with pytest.raises(OSError, match="injected"):
            baseline.cmd_baseline(
                argparse.Namespace(
                    baseline_action="promote",
                    current_dir=str(current),
                    pending_dir=str(pending),
                    target_current_dir=None,
                    yes=True,
                )
            )
    assert snapshot(tmp_path) == before


def test_baseline_overwrite_failure_keeps_old_baseline_and_packages(tmp_path):
    game, saved, files = make_baseline(tmp_path)
    before = snapshot(saved)
    plan = {
        "game_version": {},
        "files": [
            dict(
                item,
                source_game_path=str(game / item["install_relative_path"]),
                md5=md5_file(game / item["install_relative_path"]),
            )
            for item in files
        ],
    }
    args = argparse.Namespace(
        baseline_action="create",
        game_dir=str(game),
        package_dir=None,
        out_dir=str(saved),
        preferred_path=None,
        jobs=1,
        progress_jsonl=False,
        overwrite=True,
        state="current",
        yes=True,
    )
    with patch.object(baseline, "baseline_plan", return_value=plan):
        with patch.object(baseline.shutil, "copy2", side_effect=OSError("injected copy failure")):
            with pytest.raises(OSError, match="injected"):
                baseline.cmd_baseline(args)
    assert snapshot(saved) == before


def test_same_project_import_is_rejected_while_import_lock_is_owned(tmp_path):
    project = tmp_path / "project"
    source = tmp_path / "source.wav"
    source.write_bytes(b"not decoded when locked")
    args = argparse.Namespace(
        project_dir=str(project), target_folder="sources", inputs=[str(source)]
    )
    with exclusive_file_lock(project / ".fh-radio-studio/import_audio.lock"):
        with pytest.raises(CliError, match="already running"):
            import_audio.cmd_import_audio(args)
    assert not list((project / "sources").glob("*.wav"))


def test_import_temporary_outputs_are_distinct(tmp_path):
    first = import_audio._temp_output_path(tmp_path / "song.wav")
    second = import_audio._temp_output_path(tmp_path / "song.wav")
    assert first != second
    assert first.suffix == second.suffix == ".wav"


@pytest.mark.parametrize("document", ["[]", "null", "{}", '{"tracks":null}', '{"tracks":{}}'])
def test_scan_preserves_metadata_with_invalid_container_shape(tmp_path, document):
    project = tmp_path / "project"
    cache = metadata.metadata_cache_path(project)
    cache.parent.mkdir(parents=True)
    cache.write_text(document, encoding="utf-8")
    args = argparse.Namespace(project_dir=str(project), inputs=[], all_sources=True, json=True)
    with pytest.raises(CliError):
        metadata.cmd_scan_metadata(args)
    assert cache.read_text(encoding="utf-8") == document


@pytest.mark.parametrize("document", ["{broken", "[]", "null"])
def test_migration_never_replaces_unreadable_existing_metadata(tmp_path, document):
    cache = metadata.metadata_cache_path(tmp_path)
    cache.parent.mkdir(parents=True)
    cache.write_text(document, encoding="utf-8")
    with pytest.raises(CliError):
        migration.migrate_project_paths(tmp_path)
    assert cache.read_text(encoding="utf-8") == document


@pytest.mark.parametrize(
    "row",
    [
        {"TD": 1, "TrackDrop": 2},
        {"TD": 1, "markers_sec": {"TrackDrop": 2}},
        {"TL": "1 -> 3", "TL-A": 2},
        {"markers_sec": {"TD": 1}, "markers_samples": {"PD": 48000}},
        {"markers_samples": {"TD": 48000}, "time_unit": "time"},
        {"time_unit": "time", "markers_samples": {"TD": 48000}},
    ],
)
def test_json_timing_rejects_ambiguous_fields_and_units(row):
    with pytest.raises(ValueError):
        _normalized(row)


@pytest.mark.parametrize(
    "row",
    [
        {"markers_samples": {"TD": 48000}, "time_unit": "samples"},
        {"time_unit": "sample", "markers_samples": {"TD": 48000}},
    ],
)
def test_explicit_matching_nested_timing_units_are_supported(row):
    assert _normalized(row) == {"TrackDrop": 48000, "time_unit": "samples"}


def test_lock_is_released_when_owner_process_exits(tmp_path):
    lock, ready = tmp_path / "operation.lock", tmp_path / "ready"
    # Use the actual interpreter rather than the Windows venv launcher, so the
    # process terminated below is the process that owns the OS handle. Load the
    # standalone module without importing the CLI's unrelated audio dependencies.
    script = "from pathlib import Path; import runpy, sys, time; exclusive_file_lock = runpy.run_path(sys.argv[3])['exclusive_file_lock'];\nwith exclusive_file_lock(Path(sys.argv[1])):\n Path(sys.argv[2]).write_text('ready'); time.sleep(30)"
    module = Path(file_transaction.__file__).with_name("file_lock.py")
    child = subprocess.Popen(
        [
            getattr(sys, "_base_executable", sys.executable),
            "-c",
            script,
            str(lock),
            str(ready),
            str(module),
        ]
    )
    try:
        deadline = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < deadline:
            if child.poll() is not None:
                pytest.fail(f"Lock owner exited before acquiring lock: {child.returncode}")
            time.sleep(0.02)
        assert ready.exists()
        with pytest.raises(FileLockTimeout):
            with exclusive_file_lock(lock):
                pass
    finally:
        child.terminate()
        child.wait(timeout=10)
    with exclusive_file_lock(lock):
        pass
    assert lock.is_file()
