## Context
- ensure there is a session file created (see the decision-log skill)

Some time ago I had an idea of a [heimdall project](heimdall/README.md). I want to resurrect it.

Specifically, I want to be able to have my agent submit internal calls to the [application server](structure-web/packages/api).
For instance, I want to kick-off workflows or add people to whitelist, etc.

For now, the only thing I deeply care about is making the calls to the structure application server.
I've had some preparations for IO, allocators, filesystem. I still like all of that, but I don't want to spend time on that yet.

