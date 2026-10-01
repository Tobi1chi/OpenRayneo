#!/usr/bin/env python3
# Copyright 2026 Tobi1chi
# SPDX-License-Identifier: Apache-2.0
"""One local Bridge request. Run with uv run python; credentials come from env."""

import argparse
import http.client
import json
import os
from pathlib import Path
import sys
from urllib.parse import urlsplit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("method", choices=["GET", "POST", "DELETE"])
    parser.add_argument("path", help="/health or a /v1/ endpoint")
    parser.add_argument("--body", metavar="FILE", help="JSON object file, or - for stdin")
    parser.add_argument("--timeout", type=float, default=90, help="Request timeout in seconds")
    args = parser.parse_args()
    connection = None
    try:
        base = urlsplit(os.environ.get("OPENRAYNEO_API_URL", ""))
        if (base.scheme != "http" or base.hostname not in {"127.0.0.1", "localhost"}
                or base.port is None or base.username is not None or base.password is not None
                or base.path not in {"", "/"} or base.query or base.fragment):
            raise ValueError("Set OPENRAYNEO_API_URL to http://127.0.0.1:PORT from the current Bridge")
        if not (args.path == "/health" or args.path.startswith("/v1/")) or any(
            c.isspace() or c in "?#" for c in args.path
        ):
            raise ValueError("Use an endpoint path without query, fragment, or whitespace")
        headers = {}
        if not (args.method == "GET" and args.path == "/health"):
            token = os.environ.get("OPENRAYNEO_API_TOKEN", "")
            if not token or any(c.isspace() for c in token):
                raise ValueError("Set OPENRAYNEO_API_TOKEN to the current Bridge token")
            headers["Authorization"] = "Bearer " + token
        body = None
        if args.body:
            text = sys.stdin.read() if args.body == "-" else Path(args.body).read_text(encoding="utf-8")
            obj = json.loads(text)
            if not isinstance(obj, dict):
                raise ValueError("Request body must be a JSON object")
            body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
        # A fixed loopback connection bypasses proxies and never follows redirects.
        connection = http.client.HTTPConnection("127.0.0.1", base.port, timeout=args.timeout)
        connection.request(args.method, args.path, body=body, headers=headers)
        response = connection.getresponse()
        payload = json.loads(response.read())
        print(json.dumps({"http_status": response.status, "response": payload}, ensure_ascii=False, indent=2))
        return 0 if 200 <= response.status < 300 else 1
    except (ValueError, OSError, http.client.HTTPException) as error:
        # Never echo the request headers, token, or request body.
        print(f"Local API request failed ({type(error).__name__}). Check URL/token configuration, JSON input, and service status; inspect state before retrying.", file=sys.stderr)
        return 2
    finally:
        if connection is not None:
            connection.close()


if __name__ == "__main__":
    sys.exit(main())
