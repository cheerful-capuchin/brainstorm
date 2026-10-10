# Agent instructions

This repository uses Jujutsu (`jj`) for local history and Git interoperability.

- Let the configured Watchman integration capture intermediate file states.
- Use `jj`, not mutating `git` commands, for version-control operations.
- At the end of a completed conversation that changed repository content, create
  one descriptive local checkpoint with `jj checkpoint -m "Session: <summary>"`.
- Do not create an empty checkpoint.
- Do not push automatically. Push only when the user explicitly requests it.
- Never add secrets, credentials, or sensitive transient material to the
  repository.

## Session records

Record the decisions the user makes during a conversation in a session record
under `sessions/`. These records are written for agents, not for the user, so
that decisions stay durable and traceable across conversations.

- Create the record with `just session --slug "<kebab-case>" --title "<title>"`.
  Pass `--related "SESS-...,SESS-..."` when the session continues or depends on
  earlier sessions. The command prints the new file path.
- Never hand-write the ID, file name, or front matter; the script derives the ID
  from the current UTC second.
- The script writes a `title` field into the front matter. The desktop app
  requires it and shows it as the session name; never remove it.
- The script also writes `agents`, the `<harness>:<session id>` of each agent
  session that wrote to the record. Before writing to a record created in
  another conversation, run `just join SESS-...` to add yourself.
- The body below the title is free-form. Capture each decision, the reasoning
  the user gave, and the alternatives they rejected, in their own terms.
- Keep adding to the same record for the rest of the conversation instead of
  creating a new one per decision.
- Fill in the one-line `summary` field right after creating the record and
  rewrite it as decisions are added; it is what `just sessions` shows.
- Before starting related work, run `just sessions` to list every record with
  its summary, open the relevant ones, and link them through
  `related_sessions`. Use `rg` in `sessions/` for exact terms.
- The `decision-log` skill has the full instructions.
