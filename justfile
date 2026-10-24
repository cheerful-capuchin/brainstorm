set default-list := true

# The session scripts ship with the decision-log skill.
scripts := home_directory() / ".agents/skills/decision-log/scripts"

# Create a session record in sessions/ and print its path.
# `related` is a comma-separated list of session IDs.
[arg("slug", long)]
[arg("title", long)]
[arg("related", long)]
session slug title related="":
    @python3 {{scripts}}/new_session.py --slug {{quote(slug)}} --title {{quote(title)}} --related {{quote(related)}}

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

