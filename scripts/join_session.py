#!/usr/bin/env python3
"""Add the running agent's harness session to an existing session record.

Each agent that writes to a record lists itself under `agents` as
`<harness>:<session id>`, so a later agent can find its transcript or message
it. Joining twice is a no-op.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from new_session import PREFIX, SESSION_ID_PATTERN, add_agent_arguments, resolve_agent

LIST_ITEM_PREFIX = "  - "


def find_record(directory: Path, identifier: str) -> Path:
    matches = sorted(directory.glob(f"{identifier}-*.md"))
    if len(matches) != 1:
        raise ValueError(f"expected one record for {identifier}, found {len(matches)}")
    return matches[0]


def add_agent(content: str, agent: str) -> str | None:
    """Return the content with `agent` appended to `agents`, or None if listed."""
    lines = content.split("\n")
    if not lines or lines[0] != "---":
        raise ValueError("missing front matter")
    end = lines.index("---", 1) if "---" in lines[1:] else -1
    if end < 0:
        raise ValueError("unterminated front matter")

    entry = f"{LIST_ITEM_PREFIX}{agent}"
    for index in range(1, end):
        line = lines[index]
        if line == "agents: []":
            lines[index : index + 1] = ["agents:", entry]
            return "\n".join(lines)
        if line != "agents:":
            continue
        last = index
        while last + 1 < end and lines[last + 1].startswith(LIST_ITEM_PREFIX):
            last += 1
            if lines[last] == entry:
                return None
        lines.insert(last + 1, entry)
        return "\n".join(lines)

    # Records created before the `agents` field existed.
    lines[end:end] = ["agents:", entry]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Add this agent to a session record.")
    parser.add_argument("session", help=f"Session ID (example: {PREFIX}-00ABCDE)")
    add_agent_arguments(parser)
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)
    repository = Path(__file__).resolve().parent.parent

    try:
        identifier = args.session.strip().upper()
        if not SESSION_ID_PATTERN.fullmatch(identifier):
            raise ValueError(f"not a valid session ID: {identifier!r}")
        agent = resolve_agent(args.harness, args.harness_session)
        path = find_record(repository / "sessions", identifier)
        updated = add_agent(path.read_text(), agent)
        if updated is not None:
            path.write_text(updated)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(path.relative_to(repository))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
