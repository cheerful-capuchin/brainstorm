SESS-00QKRBE
.dev-env/data/sessions/sess-00qkrbe/notebooks/build-id.md

let's create a new notebook where we outlay the specifics of the implementation

For instance, when it comes to the application server, I want to follow some ideas we established in
brainstorm/sessions/SESS-00RRP6T-email-otp-templates-hot-reload-cloudflare.md and .dev-env/data/sessions/sess-00rrp6t/notebooks/02-email-otp-pr-review.md.

For instance, the core is built in rust and only the I/O is in TypeScript.
Since the build service is new, we can go even further and build it completely in rust,
have the same adapter and handler pattern, so the only thing that we do in typescript
is parse the HTTP response and execute I/O.

I really like the pattern of
http -> handler -> service -> repository

where the handler is independent from transport protocol

Let's come up with the implementation plan and patterns for this build in rust?
I imagine we don't need zod schemas to describe the request of the service anymore,
since all that validation will be done in a rust entity,
the only thing we need from TS is to pass the data in, and then all the logic
will happen in rust.

