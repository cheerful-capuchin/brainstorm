# Contributing

This repository is a working space for text-based brainstorming with humans and
AI agents. It uses Jujutsu (`jj`) to preserve intermediate edits without
requiring a manually authored commit after every save.

## History model

History has two levels:

1. Watchman asks `jj` to snapshot changed files in the background. These local
   snapshots preserve the evolution of the current working-copy change.
2. A checkpoint closes a meaningful work session. Checkpoints form the readable,
   durable history shown by `jj log` and can be pushed through the Git backend.

Background snapshots are local recovery history. They are not a substitute for
an off-machine backup, and a filesystem watcher may coalesce several extremely
rapid rewrites into one captured state.

## Prerequisites

The repository expects `jj` and Watchman. On macOS with Homebrew:

```sh
brew install jj watchman
```

Verify the repository-specific watcher configuration:

```sh
jj debug watchman status
```

The result should report that Watchman and background snapshotting are active.

## Working on a session

Edit files normally with any editor or AI tool. No staging step is needed.
Watchman snapshots changed content in the background, and most `jj` commands
also snapshot before they run.

Review the current session:

```sh
jj status
jj diff
```

When the session reaches a useful boundary, create one descriptive checkpoint:

```sh
jj checkpoint -m "Session: refine accounting event model"
```

`checkpoint` is a repository-local alias for `jj commit`. It records the current
change and starts a new empty working-copy change for the next session. Do not
create a checkpoint when nothing changed.

## Browsing intermediate snapshots

Show how the current change evolved, including the patch between snapshots:

```sh
jj evolog -p
```

Show repository operations and inspect the repository at an earlier operation:

```sh
jj op log
jj --at-op <operation-id> diff
```

Show a file from an older evolution entry without changing the working copy:

```sh
jj file show -r <commit-id> path/to/file.md
```

## Recovering an older state

First find the desired entry with `jj evolog -p` or `jj op log`. To restore the
tree from an earlier evolution entry into the current working copy:

```sh
jj restore --from <commit-id>
```

Review the result with `jj diff`, then checkpoint it if the recovery should
become a durable session boundary. The restore is itself recorded by `jj`, so
the state it replaced remains recoverable.

Use `jj op restore <operation-id>` only when intentionally restoring the entire
repository view, such as bookmarks and working-copy pointers, rather than just
file content.

## Git and remote backups

The repository is colocated: `jj` and Git share the same underlying repository.
Prefer `jj` for mutating version-control operations; ordinary read-only Git
tools remain compatible.

Do not automatically push background or conversational work. Before pushing:

1. Review `jj log` and the checkpoint contents.
2. Remove credentials, secrets, private prompts, and abandoned sensitive notes.
3. Push only to an approved private remote.

For example, after placing a bookmark on the reviewed checkpoint:

```sh
jj bookmark set main -r @-
jj git push --bookmark main
```

Unlike Git branches, `jj` bookmarks do not move forward when you checkpoint.
`main` stays on the last pushed commit until you move it, so skipping the
`jj bookmark set` step makes the push a no-op:

```
Warning: No bookmarks/tags found in the default push revset: remote_bookmarks(remote=origin)..@
Nothing changed.
```

Right after `jj checkpoint`, `@-` is the checkpoint you just created and `@` is
the new empty change, so `-r @-` is the usual target. If the working copy holds
content you have not checkpointed yet, run `jj checkpoint -m "..."` first.

Only checkpoint commits reachable from the pushed bookmark are durable on the
remote. Local evolution and operation history does not travel with a normal Git
push.

## AI-agent behavior

AI agents working in this repository follow `AGENTS.md`: they use `jj`, create
one descriptive local checkpoint after a completed conversation that changed
content, and never push unless explicitly asked.
