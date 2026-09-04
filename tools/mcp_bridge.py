#!/usr/bin/env python3
"""Bridge a stdio MCP client (Claude Desktop) to the app's HTTP MCP server.

The phone serves MCP over HTTP on the local network and requires a bearer
token. Desktop MCP clients speak newline-delimited JSON-RPC over stdio and have
no way to attach that header, so this sits between them: read a line, POST it
to the phone, write the reply back.

Deliberately dependency-free and about a hundred lines — it does no protocol
work of its own, so there is nothing here to disagree with either end about.

Usage:
    mcp_bridge.py --url http://PHONE:8787/mcp --token TOKEN

The token changes every time the server is switched off and on in the app, so
expect to update it; the bridge reports a clear error rather than hanging when
it has gone stale.
"""

import argparse
import json
import sys
import urllib.error
import urllib.request


def log(message: str) -> None:
    # stderr only: anything on stdout has to be a JSON-RPC message, and a stray
    # line there corrupts the stream for the client.
    print(f"[rew-bridge] {message}", file=sys.stderr, flush=True)


def post(url: str, token: str, payload: dict, timeout: float) -> dict | None:
    body = json.dumps(payload).encode()
    request = urllib.request.Request(
        url,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        if response.status == 202:
            return None  # a notification: acknowledged, nothing to return
        text = response.read().decode().strip()
        return json.loads(text) if text else None


def error_reply(request_id, code: int, message: str) -> dict:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True, help="e.g. http://192.168.1.18:8787/mcp")
    parser.add_argument("--token", required=True, help="from the app's assistant screen")
    # A measurement plays a sweep and records it, which takes tens of seconds;
    # the default HTTP timeout would give up long before it finishes.
    parser.add_argument("--timeout", type=float, default=180.0)
    args = parser.parse_args()

    log(f"bridging to {args.url}")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError as exc:
            log(f"ignoring unparsable input: {exc}")
            continue

        request_id = message.get("id") if isinstance(message, dict) else None
        try:
            reply = post(args.url, args.token, message, args.timeout)
        except urllib.error.HTTPError as exc:
            if exc.code == 401:
                detail = (
                    "The phone rejected the token. Switch 'Allow assistant "
                    "connections' off and on in the app and use the token it "
                    "shows now."
                )
            else:
                detail = f"The phone returned HTTP {exc.code}."
            log(detail)
            reply = error_reply(request_id, -32001, detail) if request_id is not None else None
        except urllib.error.URLError as exc:
            detail = (
                f"Could not reach {args.url} ({exc.reason}). Check the phone is "
                "awake, on the same network, and that assistant connections are on."
            )
            log(detail)
            reply = error_reply(request_id, -32002, detail) if request_id is not None else None
        except Exception as exc:  # noqa: BLE001 - the bridge must not die mid-session
            log(f"unexpected failure: {exc}")
            reply = error_reply(request_id, -32003, str(exc)) if request_id is not None else None

        if reply is not None:
            sys.stdout.write(json.dumps(reply) + "\n")
            sys.stdout.flush()

    return 0


if __name__ == "__main__":
    sys.exit(main())
