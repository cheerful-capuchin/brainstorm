#!/usr/bin/env python3
"""Create a session record that captures the user's decisions for agents.

Session IDs are `SESS-` followed by fixed-width Crockford base32 seconds since
2026-01-01T00:00:00Z, so they sort lexicographically in creation order.
"""

from __future__ import annotations

import argparse
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


def render_session(identifier: str, title: str, moment: datetime, related: list[str]) -> str:
    create_time = moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    if related:
        related_block = "related_sessions:\n" + "".join(f"  - {item}\n" for item in related)
    else:
        related_block = "related_sessions: []\n"
    return f"---\ncreate_time: {create_time}\n{related_block}---\n\n# {identifier}: {title}\n"


def create_session(
    directory: Path,
    slug: str,
    title: str,
    related: list[str],
    moment: datetime | None = None,
) -> Path:
    when = moment or datetime.now(UTC)
    identifier = session_id(when)

    collisions = list(directory.glob(f"{identifier}-*.md"))
    if collisions:
        raise FileExistsError(f"{identifier} is already in use; retry in a second")

    session_path = directory / f"{identifier}-{slug}.md"
    with session_path.open("x") as session_file:
        session_file.write(render_session(identifier, title, when, related))
    return session_path


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create a session record in progress/.")
    parser.add_argument("--slug", required=True, help="Kebab-case file name suffix")
    parser.add_argument("--title", required=True, help="Human-readable session title")
    parser.add_argument(
        "--related",
        default="",
        help="Comma-separated related session IDs (example: SESS-00ABCDE,SESS-00ABCDF)",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    repository = Path(__file__).resolve().parent.parent

    try:
        session_path = create_session(
            repository / "progress",
            validate_slug(args.slug),
            normalize_title(args.title),
            parse_related(args.related),
        )
    except (FileExistsError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(session_path.relative_to(repository))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
