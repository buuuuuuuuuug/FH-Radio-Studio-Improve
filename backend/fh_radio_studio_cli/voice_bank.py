"""Fixed-index replacement for single-FSB Vorbis banks."""

import hashlib
import struct

from .bank_expansion import _find, _fsb_records, _read_stbl, _rebuild_riff
from .common import CliError
from .fsb5 import parse_fsb5_bytes


def parts(fsb):
    info = parse_fsb5_bytes(fsb, max_samples=32768)
    if struct.unpack_from("<I", fsb, 4)[0] != 1 or struct.unpack_from("<I", fsb, 24)[0] != 15:
        raise CliError("此版本支持 FSB5 v1 Vorbis；该文件可浏览，但不能替换。")
    records, audio = _fsb_records(fsb)
    offsets = [((struct.unpack("<Q", basic)[0] >> 7) & 0x07FFFFFF) * 32 for basic, _ in records]
    if (
        not offsets
        or offsets[0] != 0
        or offsets[-1] >= len(audio)
        or any(a >= b for a, b in zip(offsets, offsets[1:]))
    ):
        raise CliError("音频数据位置无效或重叠。")
    for sample, (_, chunks) in zip(info.samples, records):
        if sample.channels not in (1, 2) or 11 not in chunks:
            raise CliError("当前仅支持单声道／双声道 Vorbis 音频。")
        if set(chunks) - {4, 11, 13}:
            raise CliError("音频包含未验证的扩展元数据，当前可浏览和试听，不能替换。")
    blobs = [audio[a:b] for a, b in zip(offsets, offsets[1:] + [len(audio)])]
    return info, records, blobs


def read_bank(raw):
    _, start, stop = _find(raw, b"SND ")
    info = parse_fsb5_bytes(raw, max_samples=32768)
    if info.bank_offset < start or info.bank_offset + info.total_size != stop:
        raise CliError("文件包含多个音频块或额外数据，暂不支持重构。")
    _, table, end = _find(raw, b"STBL")
    lookup = _read_stbl(raw[table:end])
    parsed, records, blobs = parts(raw[info.bank_offset : stop])
    if any(i >= info.num_samples for i in lookup.values()):
        raise CliError("声音映射超出条目范围。")
    return info, records, blobs, lookup


def replace_indices(raw, replacements):
    info, records, blobs, lookup = read_bank(raw)
    changes = {}
    for index, encoded in replacements.items():
        if not isinstance(index, int) or not 0 <= index < info.num_samples:
            raise CliError("替换目标编号无效。")
        replacement, new_records, new_blobs = parts(encoded)
        target = info.samples[index]
        if replacement.num_samples != 1:
            raise CliError("每次编码必须产生唯一音频条目。")
        sample = replacement.samples[0]
        if (target.frequency, target.channels) != (
            sample.frequency,
            sample.channels,
        ):
            raise CliError("替换音频的采样率或声道与原条目不一致。")
        if not 0 < sample.sample_count < 1 << 30:
            raise CliError("替换音频时长超出格式范围。")
        chunks = dict(records[index][1])
        if sample.sample_count != target.sample_count and 4 in chunks:
            cues = bytearray(chunks[4])
            if len(cues) % 260:
                raise CliError("原音频包含未识别的定位标记，请启用保持原时长。")
            for offset in range(0, len(cues), 260):
                name = cues[offset + 4 : offset + 260].split(b"\0", 1)[0]
                point = struct.unpack_from("<I", cues, offset)[0]
                if name == b"End":
                    struct.pack_into("<I", cues, offset, sample.sample_count - 1)
                elif point >= sample.sample_count:
                    raise CliError("原音频定位标记超出新选段，请启用保持原时长或选择更长的素材。")
            chunks[4] = bytes(cues)
        chunks[11] = new_records[0][1][11]
        if 13 in new_records[0][1]:
            chunks[13] = new_records[0][1][13]
        elif 13 in chunks:
            raise CliError("编码结果缺少音量峰值信息。")
        word = struct.unpack("<Q", records[index][0])[0]
        word = (word & ((1 << 34) - 1)) | (sample.sample_count << 34)
        changes[index] = (struct.pack("<Q", word), chunks, new_blobs[0])
    audio, headers = bytearray(), bytearray()
    for index, ((basic, old_chunks), blob) in enumerate(zip(records, blobs)):
        basic, chunks, blob = changes.get(index, (basic, old_chunks, blob))
        audio.extend(b"\0" * (-len(audio) % 32))
        word = struct.unpack("<Q", basic)[0]
        word = (word & ~(0x07FFFFFF << 7)) | ((len(audio) // 32) << 7)
        if len(audio) // 32 > 0x07FFFFFF:
            raise CliError("音频资源超出格式范围。")
        headers.extend(struct.pack("<Q", word))
        for pos, (kind, payload) in enumerate(chunks.items()):
            headers.extend(
                struct.pack("<I", (kind << 25) | (len(payload) << 1) | (pos + 1 < len(chunks)))
            )
            headers.extend(payload)
        audio.extend(blob)
    fsb = raw[info.bank_offset : info.bank_offset + info.total_size]
    old_headers, names = struct.unpack_from("<2I", fsb, 12)
    header = bytearray(fsb[:60])
    struct.pack_into("<3I", header, 12, len(headers), names, len(audio))
    new_fsb = (
        bytes(header)
        + bytes(headers)
        + fsb[60 + old_headers : 60 + old_headers + names]
        + bytes(audio)
    )
    _, snd, snd_end = _find(raw, b"SND ")
    _, sndh, sndh_end = _find(raw, b"SNDH")
    seek = bytearray(raw[sndh:sndh_end])
    if len(seek) != 12:
        raise CliError("该文件的定位块结构尚未支持。")
    struct.pack_into("<II", seek, 4, 0, len(new_fsb))
    replacements_by_chunk = {b"SND ": raw[snd : info.bank_offset] + new_fsb, b"SNDH": bytes(seek)}
    result = _rebuild_riff(raw, replacements_by_chunk)
    _, start, end = _find(result, b"SND ")
    struct.pack_into("<I", seek, 4, result.find(b"FSB5", start, end))
    replacements_by_chunk[b"SNDH"] = bytes(seek)
    result = _rebuild_riff(raw, replacements_by_chunk)
    final, final_records, final_blobs, final_lookup = read_bank(result)
    if final.num_samples != info.num_samples or final_lookup != lookup:
        raise CliError("重构后的条目数量或声音映射发生变化。")
    for index, blob in enumerate(blobs):
        if index not in changes and (
            hashlib.sha256(final_blobs[index]).digest() != hashlib.sha256(blob).digest()
            or final_records[index][1] != records[index][1]
        ):
            raise CliError(f"未替换的条目 {index + 1} 发生变化。")
    return result
