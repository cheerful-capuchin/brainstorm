## Context
When talking to the agents, I want them to record the decisions I'm making in a durable artifact somewhere in the brainstorm/progress.
Those artifacts are for the agents only, I'm not going to read them. The whole point is that my decisions are kept in a durable storage
and can be traced.

While I'm doing the discovery work, I would like to write all those artifacts into the brainstorm/progress.
However, if we don't have any structure, it will go bad very quickly.
Therefore, I was thinking of having something similar to the knowledge base, where there is a small python program that creates a new
decision document template with the right id, front-matter, but no restrictions regarding the content, so the agent can fill it in as it wishes.

See how the knowledge-base is structured.
I think this durable document will have the strucutre
`SESS-0A6XY`
```markdown
---
create_time: 2026-08-21
related_sessions:
  - SESS-09QHF
---

# SESS-0A6XY: {title}
```

then, we'll have brainstorm/justfile command like "session" that invokes a python script that creates this template
```
just session --slug "xyz" --title "x y z"
```
You can change the encoding to use seconds based timestamp and increase the numeric encoding length



