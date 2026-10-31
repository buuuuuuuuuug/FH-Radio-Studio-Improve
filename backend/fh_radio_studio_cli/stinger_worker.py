"""A local JSONL session avoids Python/uv startup for every editor action."""

import argparse
import contextlib
import io
import json
import sys


@contextlib.contextmanager
def request_input(value):
    previous = sys.stdin
    try:
        sys.stdin = io.StringIO(json.dumps(value or {}))
        yield
    finally:
        sys.stdin = previous


def serve(args, handler=None):
    if handler is None:
        from .stingers import cmd_stingers

        handler = cmd_stingers

    input_stream, output_stream = sys.stdin, sys.stdout
    for line in input_stream:
        request = json.loads(line)
        response = {"id": request["id"]}
        command = argparse.Namespace(**vars(args))
        action = request.get("action")
        if action in {"serve", None}:
            raise ValueError("Invalid worker action")
        for key in (
            "locale",
            "current_game",
            "slot",
            "asset_id",
            "paths",
            "bank_id",
            "source",
            "index",
        ):
            if key in request:
                setattr(command, key, request[key])
        command.action = action
        command.input_json = "-"
        command.progress_jsonl = False
        captured = io.StringIO()
        try:
            with (
                contextlib.redirect_stdout(captured),
                contextlib.redirect_stderr(captured),
                request_input(request.get("input")),
            ):
                code = handler(command)
            if code:
                raise ValueError(captured.getvalue())
            response["result"] = json.loads(captured.getvalue().splitlines()[-1])
        except Exception as error:
            response["error"] = str(error)
        output_stream.write(json.dumps(response, ensure_ascii=False) + "\n")
        output_stream.flush()
    return 0
