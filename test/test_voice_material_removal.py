import json
from test.test_voices import resource

import numpy as np
import pytest
import soundfile as sf

from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.stingers import local_file
from backend.fh_radio_studio_cli.voice_workspace import remove_assets
from backend.fh_radio_studio_cli.voices import import_assets, plan_path, prepare, save


def test_material_removal_clears_only_its_references_and_retains_source(resource, tmp_path):
    project, game, source = resource
    bank = prepare(project, game, source)["bank"]
    paths = [tmp_path / "a.wav", tmp_path / "b.wav"]
    for i, path in enumerate(paths):
        sf.write(path, np.full(4800, i / 4), 48000)
    plan = import_assets(project, paths, "素材")["plan"]
    first, second = plan["assets"]
    changes = {
        str(i): {"asset_id": asset["id"], "start": 0, "end": 0.1, "gain_db": 0}
        for i, asset in enumerate([first, second])
    }
    save(project, {bank["id"]: changes})
    snapshot = local_file(project, first["source"]).read_bytes()
    result = remove_assets(project, {"assets": [first["id"]]})
    assert result["removed"] == result["removed_replacements"] == 1
    assert result["plan"]["assets"] == [second]
    assert result["plan"]["banks"][bank["id"]]["replacements"] == {"1": changes["1"]}
    assert local_file(project, first["source"]).read_bytes() == snapshot
    assert (
        source.is_file()
        and json.loads(plan_path(project).read_text(encoding="utf-8")) == result["plan"]
    )


@pytest.mark.parametrize("ids", [[], [False], ["missing"], "all"])
def test_invalid_removal_never_changes_the_saved_plan(resource, ids):
    project, game, source = resource
    prepare(project, game, source)
    before = plan_path(project).read_bytes()
    with pytest.raises(CliError):
        remove_assets(project, {"assets": ids})
    assert plan_path(project).read_bytes() == before
