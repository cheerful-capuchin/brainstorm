set default-list := true

# The session scripts ship with the decision-log skill.
scripts := home_directory() / ".agents/skills/decision-log/scripts"

# Create a session record in sessions/, print its path, and attach it to
# dev-env so the daemon and the IntelliJ plugin serve the session at once.
# `related` is a comma-separated list of session IDs.
[arg("slug", long)]
[arg("title", long)]
[arg("related", long)]
session slug title related="":
    #!/usr/bin/env bash
    set -euo pipefail
    path=$(python3 {{scripts}}/new_session.py --slug {{quote(slug)}} --title {{quote(title)}} --related {{quote(related)}})
    echo "$path"
    # The record exists either way; a failed attach is reported, not fatal,
    # so nobody creates the record a second time.
    if ! command -v dev-env >/dev/null; then
        echo "dev-env not found; attach later with: dev-env sessions attach brainstorm/$path" >&2
    elif ! dev-env sessions attach "$path" >&2; then
        echo "attach failed; retry with: dev-env sessions attach brainstorm/$path" >&2
    fi

# Add the running agent's harness and session id to an existing record.
join session:
    @python3 {{scripts}}/join_session.py {{quote(session)}}

# List every session record, newest first: ID, date, title, summary, related.
sessions:
    @python3 {{scripts}}/list_sessions.py

sync message="sync":
    jj describe -m "{{message}}"
    jj bookmark set main -r @
    jj git push

