"""Replace selected FH6 Vorbis samples without re-encoding their neighbours."""

from __future__ import annotations

import hashlib
import struct

from .bank_expansion import _find, _fsb_records, _read_stbl, _rebuild_riff, sound_hash
from .common import CliError
from .fsb5 import parse_fsb5_bytes

OFFSET_MASK = 0x07FFFFFF << 7
LENGTH_MASK = 0x3FFFFFFF << 34


def cue_points(payload: bytes) -> dict[str, int]:
    if len(payload) % 260:
        raise CliError("台呼标记块长度无效")
    points = {}
    for offset in range(0, len(payload), 260):
        name = payload[offset + 4 : offset + 260].split(b"\0", 1)[0].decode("utf-8")
        if not name or name in points:
            raise CliError("台呼标记名称为空或重复")
        points[name] = struct.unpack_from("<I", payload, offset)[0]
    return points


def update_cues(payload: bytes, next_sample: int, samples: int) -> bytes:
    points = cue_points(payload)
    if "StartNextTrack" not in points or "End" not in points:
        raise CliError("原台呼缺少下一首开始或结束标记")
    if not 0 <= next_sample < samples:
        raise CliError("下一首开始位置必须位于台呼音频内")
    result = bytearray(payload)
    for offset in range(0, len(payload), 260):
        name = payload[offset + 4 : offset + 260].split(b"\0", 1)[0].decode("utf-8")
        value = (
            next_sample
            if name == "StartNextTrack"
            else samples - 1 if name == "End" else points[name]
        )
        if not 0 <= value < samples:
            raise CliError(f"保留的台呼标记 {name} 超出新音频范围")
        struct.pack_into("<I", result, offset, value)
    return bytes(result)


def _parts(fsb: bytes):
    info = parse_fsb5_bytes(fsb)
    version, codec = (
        struct.unpack_from("<I", fsb, 4)[0],
        struct.unpack_from("<I", fsb, 24)[0],
    )
    if version != 1 or codec != 15:
        raise CliError("当前台呼重构仅支持 FSB5 v1 Vorbis")
    records, audio = _fsb_records(fsb)
    offsets = [((struct.unpack("<Q", basic)[0] >> 7) & 0x07FFFFFF) * 32 for basic, _ in records]
    if offsets[0] != 0 or any(a >= b for a, b in zip(offsets, offsets[1:])):
        raise CliError("台呼音频数据位置无效或重叠")
    if offsets[-1] >= len(audio):
        raise CliError("台呼数据位置超出音频块")
    blobs = [audio[a:b] for a, b in zip(offsets, offsets[1:] + [len(audio)])]
    for sample, (_, chunks) in zip(info.samples, records):
        if sample.frequency != 48000 or sample.channels != 2:
            raise CliError("台呼必须保持 48000 Hz 双声道")
        if set(chunks) - {4, 11, 13} or 11 not in chunks:
            raise CliError("台呼包包含尚未验证的音频元数据")
    return info, records, blobs


def bank_samples(raw: bytes):
    _, start, stop = _find(raw, b"SND ")
    offset = raw.find(b"FSB5", start, stop)
    if offset < 0:
        raise CliError("选择的台呼包没有音频")
    info = parse_fsb5_bytes(raw)
    if offset != info.bank_offset or offset + info.total_size != stop:
        raise CliError("台呼包包含未支持的多音频块或尾部数据")
    _, table, table_end = _find(raw, b"STBL")
    lookup = _read_stbl(raw[table:table_end])
    fsb = raw[offset:stop]
    parsed, records, blobs = _parts(fsb)
    if any(index >= parsed.num_samples for index in lookup.values()):
        raise CliError("台呼声音映射超出条目范围")
    return info, records, blobs, lookup


def replace_samples(raw: bytes, replacements: dict[str, tuple[bytes, int]]) -> tuple[bytes, dict]:
    """Each replacement is a one-sample encoded FSB and its next-track cue.

    The original STBL stays byte-identical. Only changed sample payloads are
    encoded; untouched compressed payloads and their per-sample metadata survive.
    """
    if not replacements:
        return raw, {"replaced": 0, "unchanged_payloads_verified": True}
    original, records, blobs, lookup = bank_samples(raw)
    original_count = original.num_samples
    changes = {}
    for name, (encoded, next_sample) in replacements.items():
        index = lookup.get(sound_hash(name))
        if index is None or index in changes:
            raise CliError("台呼目标声音不存在或指向同一位置")
        info, new_records, new_blobs = _parts(encoded)
        if info.num_samples != 1:
            raise CliError("台呼替换必须使用可验证的单条编码结果")
        old_basic, old_chunks = records[index]
        new_basic, new_chunks = new_records[0]
        points = update_cues(old_chunks.get(4, b""), int(next_sample), info.samples[0].sample_count)
        chunks = dict(old_chunks)
        chunks[4] = points
        chunks[11] = new_chunks[11]
        if 13 in new_chunks:
            chunks[13] = new_chunks[13]
        elif 13 in chunks:
            raise CliError("编码器缺少峰值元数据，不能沿用旧音量记录")
        word = struct.unpack("<Q", old_basic)[0]
        word = (word & ~LENGTH_MASK) | (info.samples[0].sample_count << 34)
        changes[index] = (struct.pack("<Q", word), chunks, new_blobs[0])
    audio = bytearray()
    headers = bytearray()
    expected = []
    for index, ((basic, original_chunks), original_blob) in enumerate(zip(records, blobs)):
        basic, chunks, blob = changes.get(index, (basic, original_chunks, original_blob))
        audio.extend(b"\0" * (-len(audio) % 32))
        word = struct.unpack("<Q", basic)[0]
        if len(audio) // 32 > 0x07FFFFFF:
            raise CliError("台呼音频数据超过格式范围")
        word = (word & ~OFFSET_MASK) | ((len(audio) // 32) << 7)
        word = (word | 1) if chunks else (word & ~1)
        headers.extend(struct.pack("<Q", word))
        kinds = list(chunks)
        for pos, kind in enumerate(kinds):
            payload = chunks[kind]
            value = (kind << 25) | (len(payload) << 1) | (pos + 1 < len(kinds))
            headers.extend(struct.pack("<I", value))
            headers.extend(payload)
        audio.extend(blob)
        expected.append((index, hashlib.sha256(original_blob).hexdigest()))
    # Preserve the original name table, including an empty table and padding.
    old_fsb = raw[original.bank_offset : original.bank_offset + original.total_size]
    old_headers, name_size = struct.unpack_from("<2I", old_fsb, 12)
    name_table = old_fsb[60 + old_headers : 60 + old_headers + name_size]
    header = bytearray(old_fsb[:60])
    struct.pack_into("<I", header, 8, len(records))
    struct.pack_into("<3I", header, 12, len(headers), name_size, len(audio))
    new_fsb = bytes(header) + bytes(headers) + name_table + bytes(audio)
    _, snd, snd_end = _find(raw, b"SND ")
    _, sndh, sndh_end = _find(raw, b"SNDH")
    seek_header = bytearray(raw[sndh:sndh_end])
    if len(seek_header) != 12:
        raise CliError("台呼包定位块结构尚未支持")
    struct.pack_into("<II", seek_header, 4, 0, len(new_fsb))
    parts = {
        b"SND ": raw[snd : original.bank_offset] + new_fsb,
        b"SNDH": bytes(seek_header),
    }
    result = _rebuild_riff(raw, parts)
    _, new_snd, new_end = _find(result, b"SND ")
    struct.pack_into("<I", seek_header, 4, result.find(b"FSB5", new_snd, new_end))
    parts[b"SNDH"] = bytes(seek_header)
    result = _rebuild_riff(raw, parts)
    final, final_records, final_blobs, final_lookup = bank_samples(result)
    if final.num_samples != original_count or final_lookup != lookup:
        raise CliError("台呼重构改变了条目数量或声音映射")
    for index, digest in expected:
        if index not in changes and hashlib.sha256(final_blobs[index]).hexdigest() != digest:
            raise CliError(f"未替换的台呼 {index + 1} 数据发生变化")
        if index not in changes and final_records[index][1] != records[index][1]:
            raise CliError(f"未替换的台呼 {index + 1} 元数据发生变化")
    return result, {
        "replaced": len(changes),
        "slots": original.num_samples,
        "unchanged_payloads_verified": True,
        "mapping_verified": True,
    }
