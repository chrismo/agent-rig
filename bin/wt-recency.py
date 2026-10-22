"""Sort wt's picker lines by existing agent transcript modification times."""

import json
import os
from pathlib import Path
import re
import sys


def session_root(variable, default):
    return Path(os.environ.get(variable, default))


def mtime(path):
    try:
        return path.stat().st_mtime_ns
    except OSError:
        return 0


def sort_recent(lines):
    home = Path.home()
    claude = session_root("CLAUDE_PROJECTS_DIR", home / ".claude/projects")
    pi = session_root("AGENT_READ_PI_DIR", home / ".pi/agent/sessions")
    codex = session_root("AGENT_READ_CODEX_DIR", home / ".codex/sessions")
    stamps = {}
    aliases = {}
    for line in lines:
        directory = line.split("\t", 1)[0]
        stamps[directory] = 0
        aliases[directory] = directory
        aliases[os.path.realpath(directory)] = directory
        encoded = re.sub(r"[^a-zA-Z0-9]", "-", directory)
        pi_encoded = "--" + directory.lstrip("/").replace("/", "-") + "--"
        for folder in (claude / encoded, pi / pi_encoded):
            stamps[directory] = max(
                stamps[directory],
                max((mtime(file) for file in folder.glob("*.jsonl")), default=0),
            )

    # Codex partitions by date, not worktree; read each header once for its cwd.
    for file in codex.glob("*/*/*/*.jsonl"):
        try:
            with file.open() as stream:
                header = json.loads(stream.readline())
        except (OSError, ValueError):
            continue
        if not isinstance(header, dict) or header.get("type") != "session_meta":
            continue
        payload = header.get("payload")
        if not isinstance(payload, dict):
            continue
        source = payload.get("source")
        if isinstance(source, dict) and "subagent" in source:
            continue
        cwd = payload.get("cwd")
        if not isinstance(cwd, str):
            continue
        directory = aliases.get(cwd) or aliases.get(os.path.realpath(cwd))
        if directory is not None:
            stamps[directory] = max(stamps[directory], mtime(file))

    return sorted(lines, key=lambda line: stamps[line.split("\t", 1)[0]], reverse=True)


if __name__ == "__main__":
    sys.stdout.writelines(sort_recent(sys.stdin.readlines()))
