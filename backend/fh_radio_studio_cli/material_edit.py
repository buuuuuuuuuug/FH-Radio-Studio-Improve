"""Non-destructive sample-accurate material edits shared by voice and stingers."""

from __future__ import annotations

import hashlib
import json
import math
import uuid
from pathlib import Path

import numpy as np
import soundfile as sf

from .common import CliError

RATE = 48000


def _number(value):
    if isinstance(value, bool):
        raise CliError("音频编辑时间必须为有效数字。")
    try:
        value = float(value)
    except (TypeError, ValueError) as error:
        raise CliError("音频编辑时间必须为有效数字。") from error
    if not math.isfinite(value):
        raise CliError("音频编辑时间必须为有效数字。")
    return value


def validate_operations(operations, duration):
    """Times refer to the output of the preceding operation, never the source."""
    if not isinstance(operations, list) or len(operations) > 1000:
        raise CliError("音频编辑记录无效。")
    frames = round(_number(duration) * RATE)
    normalized = []
    for operation in operations:
        if not isinstance(operation, dict):
            raise CliError("音频编辑记录无效。")
        kind = operation.get("kind")
        if kind == "insert":
            at = round(_number(operation.get("at")) * RATE)
            length = round(_number(operation.get("duration")) * RATE)
            if not 0 <= at <= frames or not 1 <= length <= 3600 * RATE:
                raise CliError("静音插入位置或时长无效。")
            frames += length
            normalized.append({"kind": kind, "at": at / RATE, "duration": length / RATE})
        elif kind in {"delete", "silence"}:
            start = round(_number(operation.get("start")) * RATE)
            end = round(_number(operation.get("end")) * RATE)
            if not 0 <= start < end <= frames:
                raise CliError("选区应位于当前音频内，且结束位置须晚于开始位置。")
            if kind == "delete":
                frames -= end - start
                if frames < 1:
                    raise CliError("不能删除整段音频；如需保留空白，请使用“选区静音”。")
            normalized.append({"kind": kind, "start": start / RATE, "end": end / RATE})
        else:
            raise CliError("未知音频编辑操作。")
        if frames > 6 * 3600 * RATE:
            raise CliError("编辑后的音频过长，请减少插入静音的时长。")
    return normalized, frames / RATE


def apply_operations(pcm, operations):
    operations, _ = validate_operations(operations, len(pcm) / RATE)
    result = pcm
    for operation in operations:
        if operation["kind"] == "insert":
            at = round(operation["at"] * RATE)
            silence = np.zeros(
                (round(operation["duration"] * RATE), result.shape[1]), dtype=result.dtype
            )
            result = np.concatenate((result[:at], silence, result[at:]))
        else:
            start, end = (round(operation[k] * RATE) for k in ("start", "end"))
            if operation["kind"] == "delete":
                result = np.concatenate((result[:start], result[end:]))
            else:
                result = result.copy()
                result[start:end] = 0
    return result


def material_wave(args, project, asset, edit, *, namespace):
    """Render only when edits change; preserve imported sources and decoded PCM."""
    from .stinger_cache import asset_source, cached_wave, valid_pcm

    source = asset_source(args, project, asset, namespace=namespace)
    start = _number(edit.get("start", 0))
    end = _number(edit.get("end", asset["duration"]))
    if not 0 <= start < end <= asset["duration"] + 0.002:
        raise CliError("原选段范围无效，请恢复完整音频后重试。")
    end = min(end, asset["duration"])
    operations, duration = validate_operations(edit.get("audio_edits", []), end - start)
    if start == 0 and abs(end - source["duration"]) < 1 / RATE and not operations:
        return source
    folder = Path(project) / "analysis" / namespace / "material-edits"

    def cached_path(ops):
        key = hashlib.sha256(
            json.dumps([1, asset["sha256"], start, end, ops], sort_keys=True).encode()
        ).hexdigest()
        return folder / f"{key}.wav"

    output = cached_path(operations)
    if not valid_pcm(output, round(duration * RATE)):
        output.parent.mkdir(parents=True, exist_ok=True)
        # Reuse the longest already rendered prefix after each edit or undo.
        # Paths and sample lengths are derived here, never trusted from the UI.
        prefix = 0
        for count in range(len(operations) - 1, 0, -1):
            candidate = cached_path(operations[:count])
            if not candidate.is_file():
                continue
            _, expected = validate_operations(operations[:count], end - start)
            if valid_pcm(candidate, round(expected * RATE)):
                try:
                    pcm = sf.read(candidate, dtype="float32", always_2d=True)[0]
                    prefix = count
                    break
                except (OSError, RuntimeError):
                    # Caches are replaceable. A truncated/deleted prefix must
                    # not prevent rendering from the immutable source.
                    continue
        if prefix == 0:
            with sf.SoundFile(source["path"]) as audio:
                audio.seek(round(start * RATE))
                pcm = audio.read(round((end - start) * RATE), dtype="float32", always_2d=True)
        pcm = apply_operations(pcm, operations[prefix:])
        temporary = output.with_name(f".{output.stem}-{uuid.uuid4().hex}.tmp.wav")
        try:
            sf.write(temporary, pcm, RATE, subtype="FLOAT")
            temporary.replace(output)
        finally:
            temporary.unlink(missing_ok=True)
    result = cached_wave(output)
    if abs(result["duration"] - duration) > 2 / RATE:
        raise CliError("编辑缓存时长校验失败，请撤销本次操作后重试。")
    return result
