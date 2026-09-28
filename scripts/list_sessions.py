#!/usr/bin/env python3
"""Print one line per session record, newest first, for agents to scan.

The front matter is the fixed shape written by `new_session.py`, so this reads
it with a small line parser instead of a YAML dependency. A record that does
not parse is still listed, with a warning on stderr.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

from new_session import PREFIX, TAG_WIDTH

TITLE_PATTERN = re.compile(rf"^# {PREFIX}-\w{{{TAG_WIDTH}}}:\s*(.+?)\s*$")
FIELD_PATTERN = re.compile(r"^([a-z_]+):\s*(.*?)\s*$")
LIST_ITEM_PATTERN = re.compile(r"^\s+-\s+(.+?)\s*$")


@dataclass(frozen=True)
class Session:
    identifier: str
    create_date: str
    title: str
    summary: str
    related: list[str]


def unquote(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] == '"':
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value[1:-1]
    if len(value) >= 2 and value[0] == value[-1] == "'":
        return value[1:-1].replace("''", "'")
    return value


def parse_front_matter(lines: list[str]) -> tuple[dict[str, str], list[str], int]:
    """Return scalar fields, related session IDs, and the body start line."""
    if not lines or lines[0].strip() != "---":
        raise ValueError("missing front matter")

    fields: dict[str, str] = {}
    related: list[str] = []
    current_list: str | None = None
    for index, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            return fields, related, index + 1
        item = LIST_ITEM_PATTERN.match(line)
        if item and current_list == "related_sessions":
            related.append(item.group(1))
            continue
        field = FIELD_PATTERN.match(line)
        if field:
            key, value = field.groups()
            current_list = key if value == "" else None
            if key != "related_sessions":
                fields[key] = unquote(value)
    raise ValueError("unterminated front matter")


def load_session(path: Path) -> Session:
    identifier = path.name[: len(PREFIX) + 1 + TAG_WIDTH]
    lines = path.read_text().splitlines()
    fields, related, body_start = parse_front_matter(lines)

    title = ""
    for line in lines[body_start:]:
        heading = TITLE_PATTERN.match(line)
        if heading:
            title = heading.group(1)
            break

    return Session(
        identifier=identifier,
        create_date=fields.get("create_time", "")[:10],
        title=title or path.stem,
        summary=" ".join(fields.get("summary", "").split()),
        related=related,
    )


def format_session(session: Session) -> str:
    line = f"{session.identifier} {session.create_date} {session.title}"
    line += f" | {session.summary or '(no summary)'}"
    if session.related:
        line += f" | related: {', '.join(session.related)}"
    return line


def main() -> int:
    directory = Path(__file__).resolve().parent.parent / "sessions"
    paths = sorted(directory.glob(f"{PREFIX}-*.md"), reverse=True)
    if not paths:
        print("no session records yet")
        return 0

    for path in paths:
        try:
            print(format_session(load_session(path)))
        except (OSError, ValueError) as error:
            print(f"warning: {path.name}: {error}", file=sys.stderr)
            print(f"{path.stem} | (unreadable front matter)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
