# OTP sign-in prototype: reference snippets

## Header

- Location: `/Users/doichevkostia/work/stxr/workspace/prototypes/otp-sign-in/` (TypeScript on Bun, not Rust).
- Commit state: not committed. `git -C prototypes status` lists `otp-sign-in/` as untracked (`??`). The `prototypes` repo's last commits (`ac5256d`, `13afb11`, `419f905`) do not touch it.
- Source gap: `src/`, `docs/plans/` and the other source folders exist on disk but are empty. Only `mnt/data/*.json`, `out/` (sample rendered email and sent emails) and `node_modules/` are populated. The source-level snippets below therefore come from the plan document the agent wrote (transcript `Write` call, 2026-10-01), not from the code.
- Tests: none on disk, so no test count. The plan calls for `bun test` with colocated `*.test.ts`, table tests, and property tests.

## Design facts

- Commands on stdin:
  - `/sign-in email=foo@stxr.io;` normalizes the email, computes the identifier id, creates a challenge, renders and sends the email, and prints the signed challenge blob.
  - `/verify challenge=<blob>;code=123456;` checks the server signature and expiry, then claims the OTP row atomically, then finds or creates the user. Prints `signed in as usr_...`.
  - Parser values may be quoted with `"` so they can contain `;` and `=`. Expected failures are returned as values, not thrown.
- Identifier id: `idf_` + hex(sha256(`${type}\n${value}`)). Email is normalized by trim and lowercase, and must contain exactly one `@` and a dot in the domain.
- Challenge id: `crypto.randomUUID()`, used as the `nonce` in the signed payload and as the row id.
- Code: 6 digits from `crypto.getRandomValues` with rejection sampling (discard bytes >= 250, so the digits are unbiased).
- Code hash: HMAC-SHA-256 keyed by the server secret, over `${challengeId}\n${code}`, via WebCrypto `subtle`. Compared with a constant-time equal. The hash is per challenge, so the same code gives different hashes under different challenge ids.
- Challenge blob: `base64url(JSON payload) . base64url(HMAC-SHA-256(secret, base64url(JSON payload)))`. Payload is `{ nonce, identifierId, issuedAt, expiresAt, version: "2026-10-01" }`. The client never decodes it; it only holds the blob and sends it back with the code.
- Verify error reasons for the blob (closed set): `malformed`, `bad_signature`, `expired`.
- Verify outcomes (closed set): `signed_in | invalid_code | expired | exhausted | already_used | malformed_challenge`. A tampered blob returns `malformed_challenge` and touches no row.
- TTL: code expires after 10 minutes (`CODE_TTL_MINUTES = 10`). The email says "expires in 10 minutes and works only once".
- Attempt limit: `MAX_ATTEMPTS = 5`. The sixth attempt is `exhausted`, even with the right code.
- Single-use: a successful verify sets `usedAt`. Reuse gives `already_used`. A new sign-in marks earlier live challenges for the same identifier as used.
- Atomic claim: one `store.update` on the row, with precondition `usedAt == null && attempts < MAX_ATTEMPTS && expiresAt > now`. Effect: `attempts += 1`, and if the hash matches, `usedAt = now`. If the precondition fails, the reason is picked in this order: `already_used`, `exhausted`, `expired`. A concurrency test with two `verify` calls via `Promise.all` must yield exactly one `signed_in`.
- Rate limits: none in the plan beyond the attempt limit. No per-identifier send throttle is listed.
- Unknown-email behaviour: not handled in the PoC. No whitelist ("no need in whitelist").
- Email sending: Cloudflare Email Service REST API (`POST .../accounts/{account_id}/email/sending/send`, bearer token with `Email Sending: Edit`). Gated by `OTP_SEND=1`. Default is a dry run that writes `out/sent/<timestamp>-<to>.{html,txt,json}`. Sending needs the Workers Paid plan and verified destination addresses until a domain is onboarded. Whether a `from` on a non-onboarded domain is accepted is marked unconfirmed in the plan.
- Email composition: a hand-written table-based HTML template (`src/email/templates/otp.html`) plus a plain-text twin (`otp.txt`). Placeholders `{{name}}` with strict rendering: every value is HTML-escaped, and a missing or unused variable is an error. Raw (unescaped) placeholders are deliberately not supported. No JSX, no template engine.
- Preview tool: `Bun.serve` on `127.0.0.1:8787`. Left pane is a form with one input per template variable, right pane an iframe of `/render`. Also `/text` and `/json` (request body with the token redacted). Re-reads template files on each request.
- Storage: one JSON file per table at `mnt/data/<table>.json`, shaped `{ "table": "<name>", "data": { "<id>": row } }`. Tables are a closed set: `identifiers`, `otp_challenges`, `users`. Writes go to a temp file, then rename.
- Secrets: from env (`CF_ACCOUNT_ID`, `CF_API_TOKEN`, `OTP_FROM_ADDRESS`, `OTP_FROM_NAME`, `OTP_SERVER_SECRET`, `OTP_SEND`). `.env` is gitignored.
- Error style: expected failures are values (`Result`), exceptions only for programmer errors. Sender errors are a closed set: `network | rejected | rate_limited | invalid_message`.
- Stack: Bun, TypeScript 5.9 strict, zod 4.4.3, prettier, `just check` = fmt + typecheck + test.

## Key snippets

### Challenge blob and OTP row claim (from the plan, `docs/plans/2026-10-01-otp-sign-in-poc.md`, Technical Details)

```text
<base64url(JSON payload)>.<base64url(HMAC-SHA-256(secret, base64url(JSON payload)))>
payload = { "nonce": "<uuid>", "identifierId": "idf_…", "issuedAt": "<iso>", "expiresAt": "<iso>", "version": "2026-10-01" }
```

The client never decodes it. `verify` checks the signature, then the expiry
from the payload, then loads the row by `nonce`.

```text
precondition: usedAt == null && attempts < MAX_ATTEMPTS && expiresAt > now
effect:       attempts += 1; if hash(code) == codeHash then usedAt = now
result:       matched: boolean
```

If the precondition fails, the row is unchanged and the reason is derived from
which clause failed, in this order: `already_used`, `exhausted`, `expired`.

### Planned OTP row (from the plan, Task 8)

```text
row: { id, identifierId, codeHash, issuedAt, expiresAt, attempts, usedAt: null | string }
constants: CODE_TTL_MINUTES = 10, MAX_ATTEMPTS = 5
```

### Stored row as it exists on disk (`mnt/data/otp_challenges.json`, abridged)

```json
{
  "table": "otp_challenges",
  "data": {
    "28257985-4430-4fdf-b362-a5417ea26f5a": {
      "id": "28257985-4430-4fdf-b362-a5417ea26f5a",
      "identifierId": "idf_0cb05734fe21bfec67172a28dce1a0b49ffd67a9ce6396cf755c951230f62abb",
      "codeHash": "2507430961a0e99a3285c7727ff1b15a27315ef7bf21475b104a564b0747c7a4",
      "issuedAt": "2026-10-01T15:40:37.323Z",
      "expiresAt": "2026-10-01T15:50:37.323Z",
      "attempts": 1,
      "usedAt": "2026-10-01T15:42:23.695Z"
    }
  }
}
```

### Cloudflare request body (from the plan, Technical Details)

```json
{
  "from": "Structure <no-reply@<sending-domain>>",
  "to": "foo@stxr.io",
  "subject": "123456 is your Structure sign-in code",
  "html": "<!doctype html>…",
  "text": "Your Structure sign-in code is 123456 …"
}
```

### Planned signatures (from the plan, Tasks 2 to 8)

```text
Store.open(dir); get(table, id); put(table, id, row); update(table, id, fn); list(table)
  update: fn returns the new row or a rejection reason; the file is unchanged on rejection

generateCode(length = 6)                    // crypto.getRandomValues, discard bytes >= 250
hashCode(secret, challengeId, code)         // HMAC-SHA-256 over `${challengeId}\n${code}`
sign(secret, payload) -> blob
verify(secret, blob, now) -> payload | "malformed" | "bad_signature" | "expired"

signIn({ store, sender, secret, now, email, from })
  -> { challenge: signedBlob, expiresAt, destinationMasked } | send error (row deleted)

verify({ store, secret, now, challenge, code })
  -> "signed_in" (+ user) | "invalid_code" | "expired" | "exhausted" | "already_used" | "malformed_challenge"

EmailSender.send({ from, fromName, to, subject, html, text }) -> Promise<Result<SendReceipt, SendError>>
SendError = "network" | "rejected" | "rate_limited" | "invalid_message"
```

### Email render rules (from the plan, Task 5)

```text
render(template, vars): HTML-escape every value.
  error if a placeholder has no variable, or a variable has no placeholder (strict both ways).
  {{{raw}}} is deliberately not supported.
buildOtpEmail(input) -> { subject, html, text }
  subject: "{{code}} is your {{app_name}} sign-in code"   (code shown as "123 456" in body, unsplit in subject)
```

### Email variables (from the plan)

| Variable | Example |
|---|---|
| `code` | `123 456` (display) |
| `expires_minutes` | `10` |
| `destination` | `f***@stxr.io` |
| `request_time` | `2026-10-01 11:02 UTC` |
| `app_name` | `Structure` |
| `support_email` | `support@stxr.io` |

### Sample rendered plain-text email (`out/otp.txt`, a dry-run output)

```text
Your Structure sign-in code

Enter this code to finish signing in to Structure as f***@stxr.io:

    123 456

This code expires in 10 minutes and works only once.

If you did not request this code, you can ignore this email. No one can sign in without it.

Requested on 2026-10-01 11:02 UTC. For your security, never share this code with anyone. Structure will never ask you for it.
```

## User intent quotes

> Create a new repo in prototypes/otp-sign-in.

> no need in whitelist

> build the challenge, the code, embed the code in the HTML email (this part must be as if it's a prod application). We need to have a beautiful email

> The email part must have a simple way to preview the email visually.

> Before we send any emails, I want to polish it up.

> Return an HMAC-signed challenge like the SIWS payload: nonce is the challenge id, plus identifier, client id, issued and expiration times. The client holds this and sends it back with the code.

> Okay, fine, let's try the challenge with server signature. I assume I don't even need to decode it on the client. I just hold on to it and send it back once the code has arrived?

> **Unknown email behaviour.** ... For email I would return a generic success on request ... or return the same error for consistency with the wallet flow. The second is friendlier, the first leaks less.

> We'll get rid of the "deposits" idea and have the proper whitelist flow

> You have the OTP and then you have the magic link. Do you just embed the challenge in the uri of the magic link?

> Okay, let's come back to the OTP. How does the authentication work here? Do I just update the authChallengesTable and keep the otp there or should there be a different place to store them?

> How do you compose the emai? Do you use some JS templating? Do we use JSX?

> I want a PoC with cloudflare. Create a plan for the subagent.
