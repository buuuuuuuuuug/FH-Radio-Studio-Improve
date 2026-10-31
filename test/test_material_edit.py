import numpy as np
import pytest

from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.material_edit import RATE, apply_operations, validate_operations


def test_insert_delete_and_silence_use_the_current_timeline():
    source = np.arange(RATE, dtype=np.float32).reshape(-1, 1)
    original = source.copy()
    operations = [
        {"kind": "insert", "at": 0.2, "duration": 0.1},
        {"kind": "delete", "start": 0.5, "end": 0.6},
        {"kind": "silence", "start": 0.7, "end": 0.8},
    ]
    result = apply_operations(source, operations)
    assert len(result) == RATE
    np.testing.assert_array_equal(source, original)
    np.testing.assert_array_equal(result[:9600], source[:9600])
    assert np.all(result[9600:14400] == 0)
    np.testing.assert_array_equal(result[14400:24000], source[9600:19200])
    np.testing.assert_array_equal(result[24000:33600], source[24000:33600])
    assert np.all(result[33600:38400] == 0)
    np.testing.assert_array_equal(result[38400:], source[38400:])


@pytest.mark.parametrize(
    "operation",
    [
        {"kind": "insert", "at": 2, "duration": 0.1},
        {"kind": "insert", "at": 0, "duration": float("nan")},
        {"kind": "delete", "start": 0, "end": 1},
        {"kind": "silence", "start": -0.1, "end": 0.2},
        {"kind": "unknown"},
    ],
)
def test_invalid_edits_never_touch_pcm(operation):
    source = np.ones((RATE, 2), dtype=np.float32)
    with pytest.raises(CliError):
        apply_operations(source, [operation])
    assert np.all(source == 1)


def test_edges_and_full_silence_are_sample_accurate():
    source = np.ones((RATE, 2), dtype=np.float32)
    result = apply_operations(source, [{"kind": "silence", "start": 0, "end": 1}])
    assert result.shape == source.shape
    assert not result.any()
    normalized, duration = validate_operations([{"kind": "insert", "at": 1, "duration": 0.1}], 1)
    assert duration == 1.1
    assert normalized[0]["duration"] == 0.1
