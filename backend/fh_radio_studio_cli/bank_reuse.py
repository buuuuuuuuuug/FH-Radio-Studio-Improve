"""Content-checked reuse of completed radio banks and atomic package publication."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import tempfile
from contextlib import ExitStack
from copy import deepcopy
from dataclasses import dataclass
from functools import wraps
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path

from .common import CliError
from .file_lock import FileLockTimeout, exclusive_file_lock
from .package_publication import (
    check_target,
    completed_packages,
    mark_complete,
    owned_sibling,
    publish_completed,
)

VERSION = 1


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _digest(value) -> str:
    return hashlib.sha256(
        json.dumps(
            value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False
        ).encode("utf-8")
    ).hexdigest()


def _public_unit(value):
    if isinstance(value, dict):
        return {
            key: _public_unit(item)
            for key, item in value.items()
            if not key.startswith("_runtime_")
            and key not in {"bank_build", "bank_reused", "reused_from"}
        }
    if isinstance(value, list):
        return [_public_unit(item) for item in value]
    return value


def engine_signature(ffmpeg, fsbankcl):
    root = Path(__file__).parent
    # Any backend code affecting decoding, normalization, markers or bank layout
    # invalidates old results; do not rely on a manually maintained module list.
    code = {
        str(path.relative_to(root).as_posix()): file_sha256(path)
        for path in sorted(root.rglob("*.py"))
    }
    dependencies = {}
    for name in ("numpy", "soundfile", "scipy", "librosa", "pyloudnorm", "soxr"):
        try:
            dependencies[name] = version(name)
        except PackageNotFoundError:
            dependencies[name] = None
    tools = {}
    for name, value in [("ffmpeg", ffmpeg), ("fsbankcl", fsbankcl)]:
        if value:
            path = Path(value).resolve()
            tools[name] = file_sha256(path)
            if name == "fsbankcl":
                tools["fsbank_dlls"] = {
                    p.name: file_sha256(p) for p in sorted(path.parent.glob("*.dll"))
                }
        else:
            tools[name] = None
    return _digest({"code": code, "dependencies": dependencies, "tools": tools})


def radio_fingerprint(*, radio, source_bank, target_names, tracks, settings, engine):
    return _digest(
        {
            "version": VERSION,
            "radio": radio,
            "source_bank": file_sha256(source_bank),
            "target_names": target_names,
            "tracks": tracks,
            "settings": settings,
            "engine": engine,
        }
    )


def load_previous_units(package):
    if not package:
        return []
    path = Path(package).expanduser()
    if not path.is_file():
        candidates = [
            path / "fh_radio_studio_package_manifest.json",
            path / "package/fh_radio_studio_package_manifest.json",
        ]
        path = next((item for item in candidates if item.is_file()), candidates[-1])
    try:
        manifest = json.loads(path.read_text(encoding="utf-8-sig"))
        if manifest.get("skip_bank"):
            return []
        radios = manifest.get("radios")
        if not isinstance(radios, list):
            return []
        return [(path.parent, unit) for unit in radios if isinstance(unit, dict)]
    except (OSError, ValueError, AttributeError):
        return []


@dataclass(frozen=True)
class ReusableBank:
    source: Path
    unit: dict

    def copy_to(self, directory: Path):
        target = directory / self.source.name
        directory.mkdir(parents=True, exist_ok=True)
        if self.source.resolve() != target.resolve():
            shutil.copy2(self.source, target)
        if file_sha256(target) != self.unit["bank_build"]["bank_sha256"]:
            raise CliError("复用的 bank 在复制期间发生变化，已保留上次准备包，请重试")
        unit = deepcopy(self.unit)
        unit["bank_reused"] = True
        return unit


def reusable_bank(previous, *, radio, bank_name, fingerprint):
    for root, unit in previous:
        record = unit.get("bank_build")
        if (
            unit.get("radio") != radio
            or unit.get("target_bank_name") != bank_name
            or not isinstance(record, dict)
            or record.get("version") != VERSION
            or record.get("fingerprint") != fingerprint
        ):
            continue
        try:
            if record.get("unit_sha256") != _digest(_public_unit(unit)):
                continue
        except (ValueError, TypeError):
            # Invalid optional reuse metadata must not prevent a fresh build.
            continue
        bank = root / "media/audio/FMODBanks" / bank_name
        try:
            if file_sha256(bank) == record.get("bank_sha256"):
                return ReusableBank(bank, unit)
        except OSError:
            continue
    return None


def stamp_unit(unit, fingerprint, bank):
    unit["bank_reused"] = False
    unit["bank_build"] = {
        "version": VERSION,
        "fingerprint": fingerprint,
        "bank_sha256": file_sha256(bank),
        "unit_sha256": _digest(_public_unit(unit)),
    }


def atomic_package_build(function):
    """Keep the last completed package available until a new one is complete."""

    @wraps(function)
    def publish(args):
        from .stingers import freeze_for_build

        frozen_stingers = freeze_for_build(args)
        # General voices have their own package; song/stinger publishing stays separate.
        frozen_voices = None
        target = Path(args.out_dir).expanduser().absolute()
        check_target(target)
        manifest = target / "package/fh_radio_studio_package_manifest.json"
        target.parent.mkdir(parents=True, exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix=f".{target.name}-building-", dir=target.parent))
        if getattr(args, "defer_publish", False):
            print(
                "FH_RADIO_STUDIO_PACKAGE_STAGE "
                + json.dumps({"target": str(target), "stage": str(stage)}),
                flush=True,
            )

        # Validate exact owned paths before any recursive cleanup or rename.
        def owned(path):
            return owned_sibling(target, path)

        clone = argparse.Namespace(**vars(args))
        clone._stinger_snapshot = frozen_stingers
        clone._voice_snapshot = frozen_voices
        clone.out_dir = str(stage)
        clone._publish_out_dir = str(target)
        ready = completed_packages(target)
        clone.reuse_package = (
            getattr(args, "reuse_package", None)
            or (str(ready[0]) if ready else None)
            or (str(target) if manifest.is_file() else None)
        )
        completed = False
        try:
            result = function(clone)
            if result != 0:
                return result
            if clone._stinger_snapshot is not None or frozen_voices is not None:
                from .package_delta import finalize_changed_files, prepare_radioinfo_base
                from .stingers import compose_package

                prepare_radioinfo_base(clone)
                if clone._stinger_snapshot is not None:
                    compose_package(clone)
                finalize_changed_files(clone)
            if not (stage / "package/fh_radio_studio_package_manifest.json").is_file():
                raise CliError("构建未生成完整准备包清单，已保留旧准备包")
            mark_complete(target, stage)
            completed = True
            if getattr(args, "defer_publish", False):
                print(
                    "FH_RADIO_STUDIO_PACKAGE_READY "
                    + json.dumps({"target": str(target), "ready": str(stage)}),
                    flush=True,
                )
                return result
            publish_completed(target, stage)
            return result
        finally:
            if stage.exists() and not completed:
                shutil.rmtree(owned(stage))

    @wraps(function)
    def build(args):
        target = Path(args.out_dir).expanduser().absolute()
        with ExitStack() as stack:
            try:
                stack.enter_context(
                    exclusive_file_lock(target.with_name(f".{target.name}.build.lock"))
                )
            except FileLockTimeout as error:
                raise CliError("此准备包正在构建，请等待当前构建完成后重试。") from error
            return publish(args)

    return build


def published_path(args, path):
    final = getattr(args, "_publish_out_dir", None)
    if not final:
        return path
    try:
        relative = Path(path).absolute().relative_to(Path(args.out_dir).absolute())
    except ValueError:
        return path
    return Path(final) / relative
