#!/usr/bin/env -S uv run python
# Copyright 2026 Tobi1chi
# SPDX-License-Identifier: Apache-2.0
"""Run a local authenticated Codex endpoint for OpenRayneo Android."""
import argparse
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, default=Path.cwd())
    parser.add_argument("--port", type=int, default=4500)
    parser.add_argument("--config-dir", type=Path, default=Path.home() / ".config" / "openrayneo")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--phone-config", type=Path, help="Write an import file; contains a device access token")
    args = parser.parse_args()
    workspace = args.workspace.expanduser().resolve(strict=True)
    if not workspace.is_dir() or not 1024 <= args.port <= 65535:
        parser.error("Use a workspace directory and a port between 1024 and 65535")
    executable = shutil.which("codex")
    if executable is None:
        parser.error("Install Codex CLI and sign in on this computer first")
    config = args.config_dir.expanduser().resolve()
    config.mkdir(parents=True, exist_ok=True, mode=0o700)
    token_file = config / "phone-token"
    if not token_file.exists():
        with open(token_file, "x", opener=lambda path, flags: os.open(path, flags, 0o600)) as stream:
            stream.write(secrets.token_urlsafe(32))
    token_file.chmod(0o600)
    if args.phone_config:
        export = args.phone_config.expanduser().resolve()
        export.parent.mkdir(parents=True, exist_ok=True)
        data = {"codexUrl": f"ws://127.0.0.1:{args.port}", "codexToken": token_file.read_text().strip(), "codexCwd": str(workspace)}
        with open(export, "w", opener=lambda path, flags: os.open(path, flags, 0o600)) as stream:
            json.dump(data, stream, ensure_ascii=False, indent=2)
        export.chmod(0o600)
        print(f"Phone import file: {export}", flush=True)
    print(f"Endpoint: ws://127.0.0.1:{args.port}; workspace: {workspace}", flush=True)
    print(f"USB forwarding: adb reverse tcp:{args.port} tcp:{args.port}", flush=True)
    if args.prepare_only:
        return
    command = [executable, "app-server", "--listen", f"ws://127.0.0.1:{args.port}",
               "--ws-auth", "capability-token", "--ws-token-file", str(token_file),
               "-c", 'approval_policy="on-request"', "-c", 'sandbox_mode="workspace-write"']
    process = subprocess.Popen(command, cwd=workspace)
    try:
        raise SystemExit(process.wait())
    except KeyboardInterrupt:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


if __name__ == "__main__":
    main()
