import argparse
import io
import json
from unittest.mock import patch

from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.stinger_worker import serve


def test_session_recovers_after_bad_request_and_keeps_request_input_separate():
    requests = [
        {"id": 1, "action": "update", "input": {"bad": True}},
        {"id": 2, "action": "catalog", "locale": "EN", "input": {"good": True}},
    ]
    commands = []

    def command(args):
        import sys

        value = json.load(sys.stdin)
        commands.append((args.action, args.locale, value))
        if value.get("bad"):
            raise CliError("Invalid edit")
        print(json.dumps({"ready": True}))
        return 0

    output = io.StringIO()
    with (
        patch("sys.stdin", io.StringIO("\n".join(map(json.dumps, requests)))),
        patch("sys.stdout", output),
        patch("backend.fh_radio_studio_cli.stingers.cmd_stingers", command),
    ):
        serve(argparse.Namespace(locale="JP", action="serve"))
    replies = list(map(json.loads, output.getvalue().splitlines()))
    assert replies[0] == {"id": 1, "error": "Invalid edit"}
    assert replies[1] == {"id": 2, "result": {"ready": True}}
    assert commands == [("update", "JP", {"bad": True}), ("catalog", "EN", {"good": True})]
