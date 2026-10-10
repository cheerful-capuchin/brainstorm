#!/usr/bin/env python3
"""Create a session record that captures the user's decisions for agents.

Session IDs are `SESS-` followed by fixed-width Crockford base32 seconds since
2026-01-01T00:00:00Z, so they sort lexicographically in creation order.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from datetime import UTC, datetime
from pathlib import Path

EPOCH = datetime(2026, 1, 1, 0, 0, tzinfo=UTC)
CROCKFORD_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
# 7 base32 chars hold 32**7 - 1 seconds, roughly 1089 years past the epoch.
TAG_WIDTH = 7
PREFIX = "SESS"
SLUG_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
SESSION_ID_PATTERN = re.compile(rf"^{PREFIX}-[{CROCKFORD_ALPHABET}]{{{TAG_WIDTH}}}$")
HARNESS_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
HARNESS_SESSION_PATTERN = re.compile(r"^[A-Za-z0-9._-]+$")
# Environment variables that name the agent harness session running the script.
# The first variable that is set wins.
HARNESS_ENVIRONMENT = (
    ("claude-code", "CLAUDE_CODE_SESSION_ID"),
    ("codex", "CODEX_THREAD_ID"),
)


def seconds_since_epoch(moment: datetime) -> int:
    if moment.tzinfo is None:
        raise ValueError("timestamp must be timezone-aware (use UTC)")
    delta = moment.astimezone(UTC) - EPOCH
    if delta.total_seconds() < 0:
        raise ValueError("timestamp must be on or after 2026-01-01T00:00:00Z")
    return int(delta.total_seconds())


def encode_tag(seconds: int, width: int = TAG_WIDTH) -> str:
    if seconds < 0:
        raise ValueError("seconds must be non-negative")
    max_value = 32**width - 1
    if seconds > max_value:
        raise ValueError(
            f"seconds {seconds} exceeds {width}-char Crockford base32 capacity ({max_value})"
        )

    chars: list[str] = []
    value = seconds
    for _ in range(width):
        chars.append(CROCKFORD_ALPHABET[value % 32])
        value //= 32
    return "".join(reversed(chars))


def session_id(moment: datetime) -> str:
    return f"{PREFIX}-{encode_tag(seconds_since_epoch(moment))}"


def normalize_title(title: str) -> str:
    normalized = " ".join(title.split())
    if not normalized:
        raise ValueError("title must not be empty")
    return normalized


def quote_title(title: str) -> str:
    """Quote a title for the `title:` front matter field.

    The desktop app reads the field by trimming the value and stripping one pair
    of matching surrounding quotes, with no escape processing. A title round-trips
    only if it does not contain the quote character wrapped around it.
    """
    if '"' not in title:
        return f'"{title}"'
    if "'" not in title:
        return f"'{title}'"
    raise ValueError("title must not contain both \" and ' characters")


def validate_slug(slug: str) -> str:
    if not SLUG_PATTERN.fullmatch(slug):
        raise ValueError(f"slug must be lowercase kebab-case (a-z, 0-9, '-'): {slug!r}")
    return slug


def parse_related(related: str) -> list[str]:
    identifiers = [item.strip().upper() for item in related.split(",") if item.strip()]
    for identifier in identifiers:
        if not SESSION_ID_PATTERN.fullmatch(identifier):
            raise ValueError(f"related session is not a valid session ID: {identifier!r}")
    return identifiers


def resolve_agent(harness: str, harness_session: str) -> str:
    """Return the `<harness>:<session id>` entry for the agent running the script.

    Explicit arguments win; otherwise the harness is detected from its
    environment variables.
    """
    if bool(harness) != bool(harness_session):
        raise ValueError("pass --harness and --harness-session together")
    if not harness:
        for name, variable in HARNESS_ENVIRONMENT:
            value = os.environ.get(variable, "").strip()
            if value:
                harness, harness_session = name, value
                break
        else:
            raise ValueError(
                "cannot detect the agent harness; pass --harness and --harness-session"
            )
    if not HARNESS_PATTERN.fullmatch(harness):
        raise ValueError(f"harness must be lowercase kebab-case: {harness!r}")
    if not HARNESS_SESSION_PATTERN.fullmatch(harness_session):
        raise ValueError(f"harness session id has unexpected characters: {harness_session!r}")
    return f"{harness}:{harness_session}"


def render_list(key: str, items: list[str]) -> str:
    if not items:
        return f"{key}: []\n"
    return f"{key}:\n" + "".join(f"  - {item}\n" for item in items)


def render_session(
    identifier: str, title: str, moment: datetime, related: list[str], agent: str
) -> str:
    create_time = moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    return (
        f"---\ncreate_time: {create_time}\ntitle: {quote_title(title)}\n"
        f"summary: \"\"\n{render_list('related_sessions', related)}"
        f"{render_list('agents', [agent])}---\n\n"
        f"# {identifier}: {title}\n"
    )


def create_session(
    directory: Path,
    slug: str,
    title: str,
    related: list[str],
    agent: str,
    moment: datetime | None = None,
) -> Path:
    when = moment or datetime.now(UTC)
    identifier = session_id(when)
    # Render before touching the disk so a rejected title leaves no empty file.
    content = render_session(identifier, title, when, related, agent)

    collisions = list(directory.glob(f"{identifier}-*.md"))
    if collisions:
        raise FileExistsError(f"{identifier} is already in use; retry in a second")

    directory.mkdir(exist_ok=True)
    session_path = directory / f"{identifier}-{slug}.md"
    with session_path.open("x") as session_file:
        session_file.write(content)
    return session_path


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create a session record in sessions/.")
    parser.add_argument("--slug", required=True, help="Kebab-case file name suffix")
    parser.add_argument("--title", required=True, help="Human-readable session title")
    parser.add_argument(
        "--related",
        default="",
        help="Comma-separated related session IDs (example: SESS-00ABCDE,SESS-00ABCDF)",
    )
    add_agent_arguments(parser)
    return parser.parse_args(argv)


def add_agent_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--harness",
        default="",
        help="Agent harness name (example: claude-code); detected from the environment if omitted",
    )
    parser.add_argument(
        "--harness-session",
        default="",
        help="Session id inside the harness; detected from the environment if omitted",
    )


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    repository = Path(__file__).resolve().parent.parent

    try:
        session_path = create_session(
            repository / "sessions",
            validate_slug(args.slug),
            normalize_title(args.title),
            parse_related(args.related),
            resolve_agent(args.harness, args.harness_session),
        )
    except (FileExistsError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(session_path.relative_to(repository))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
