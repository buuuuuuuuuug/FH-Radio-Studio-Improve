import struct

import pytest

from backend.fh_radio_studio_cli.bank_expansion import _find, _rebuild_riff, sound_hash
from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.stinger_bank import (
    bank_samples,
    cue_points,
    replace_samples,
    update_cues,
)
from backend.fh_radio_studio_cli.stingers import local_file, validate_edit


def chunk(tag, data):
    return tag + struct.pack("<I", len(data)) + data + b"\0" * (len(data) % 2)


def cues(next_sample=800, samples=1000, extra=False):
    entries = [("StartNextTrack", next_sample), ("End", samples - 1)]
    if extra:
        entries.insert(0, ("WAVE", 0))
    return b"".join(
        struct.pack("<I", value) + name.encode().ljust(256, b"\0") for name, value in entries
    )


def fsb(count, *, samples=1000, payload=23, with_cues=True):
    headers = bytearray()
    for index in range(count):
        word = 1 | (9 << 1) | (1 << 5) | (index << 7) | (samples << 34)
        headers += struct.pack("<Q", word)
        parts = ([(4, cues(samples // 2, samples, index == 1))] if with_cues else []) + [
            (11, b"codebook"),
            (13, struct.pack("<f", 0.5)),
        ]
        for pos, (kind, data) in enumerate(parts):
            headers += (
                struct.pack("<I", kind << 25 | len(data) << 1 | (pos + 1 < len(parts))) + data
            )
    header = bytearray(60)
    struct.pack_into("<4s6I", header, 0, b"FSB5", 1, count, len(headers), 0, count * 32, 15)
    return bytes(header) + headers + b"".join(bytes([payload + i]) * 32 for i in range(count))


def bank(names):
    pairs = sorted((sound_hash(name), i) for i, name in enumerate(names))
    table = struct.pack("<IiH", 1, 0, len(names)) + b"".join(
        struct.pack("<Q", key) for key, _ in pairs
    )
    table += (
        struct.pack("<H", len(names))
        + b"".join(i.to_bytes(3, "little") for _, i in pairs)
        + struct.pack("<I", 4)
    )
    encoded = fsb(len(names))
    body = b"FEV " + chunk(
        b"LIST",
        b"PROJ"
        + chunk(b"STBL", table)
        + chunk(b"SNDH", struct.pack("<3I", 524291, 0, len(encoded))),
    )
    body += chunk(b"SND ", bytes(16) + encoded)
    raw = b"RIFF" + struct.pack("<I", len(body)) + body
    _, start, end = _find(raw, b"SND ")
    return _rebuild_riff(
        raw,
        {b"SNDH": struct.pack("<3I", 524291, raw.find(b"FSB5", start, end), len(encoded))},
    )


def test_noop_is_byte_identical():
    original = bank(["a", "b", "c"])
    assert replace_samples(original, {})[0] == original


@pytest.mark.parametrize("index", [0, 1, 2])
def test_only_selected_audio_changes_and_mapping_survives(index):
    names = ["alpha", "beta", "gamma"]
    original = bank(names)
    output, checks = replace_samples(
        original,
        {names[index]: (fsb(1, samples=1400, payload=91, with_cues=False), 1000)},
    )
    old_info, old_records, old_audio, old_lookup = bank_samples(original)
    info, records, audio, lookup = bank_samples(output)
    assert info.num_samples == old_info.num_samples == 3
    assert lookup == old_lookup
    for i in range(3):
        if i == index:
            assert audio[i] == bytes([91]) * 32
            assert info.samples[i].sample_count == 1400
            assert cue_points(records[i][1][4])["StartNextTrack"] == 1000
            assert cue_points(records[i][1][4])["End"] == 1399
            if i == 1:
                assert cue_points(records[i][1][4])["WAVE"] == 0
        else:
            assert audio[i] == old_audio[i]
            assert records[i][1] == old_records[i][1]
    assert checks["unchanged_payloads_verified"]


def test_equal_duration_entries_are_not_matched_by_length():
    output, _ = replace_samples(
        bank(["first", "second"]),
        {
            "second": (fsb(1, payload=100, with_cues=False), 900),
            "first": (fsb(1, payload=90, with_cues=False), 800),
        },
    )
    _, _, audio, mapping = bank_samples(output)
    assert audio[mapping[sound_hash("first")]] == bytes([90]) * 32
    assert audio[mapping[sound_hash("second")]] == bytes([100]) * 32


def test_unknown_target_and_multisample_encoding_rejected():
    with pytest.raises(CliError):
        replace_samples(bank(["a"]), {"unknown": (fsb(1), 100)})
    with pytest.raises(CliError):
        replace_samples(bank(["a"]), {"a": (fsb(2), 100)})


@pytest.mark.parametrize("next_sample", [-1, 1000, 2000])
def test_out_of_bounds_cues_rejected(next_sample):
    with pytest.raises(CliError):
        update_cues(cues(), next_sample, 1000)


def test_input_edit_validation_rejects_nan_and_wrong_ranges():
    plan = {"assets": [{"id": "x", "duration": 20}]}
    edit = {"asset_id": "x", "start": 0, "end": 10, "gain_db": -6, "next_track": 9}
    assert validate_edit(plan, {}, edit)[1:] == (480000, 432000)
    for changes in (
        {"start": -1},
        {"next_track": 10},
        {"gain_db": float("nan")},
        {"end": 30},
    ):
        with pytest.raises(CliError):
            validate_edit(plan, {}, {**edit, **changes})


def test_material_cannot_resolve_outside_project(tmp_path):
    with pytest.raises(CliError):
        local_file(tmp_path, "C:/external.wav")
    with pytest.raises((CliError, ValueError)):
        local_file(tmp_path, "fh-project:/sources/../../external.wav")
