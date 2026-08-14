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
