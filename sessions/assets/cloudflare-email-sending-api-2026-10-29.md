# Cloudflare Email Service, Email Sending REST API (facts checked 2026-10-29)

Status: "Email Sending (Beta)", public beta since 2026-04-16, no GA entry.
Sources: developers.cloudflare.com/email-service/ and the API reference under
developers.cloudflare.com/api/resources/email_sending/.

## Send

- `POST https://api.cloudflare.com/client/v4/accounts/{account_id}/email/sending/send`
  with `Authorization: Bearer <token>` and `Content-Type: application/json`.
  Token permission "Email Sending: Edit" (account-owned token recommended).
- Body: `from` string or `{address, name}` (REST uses `address`; the Workers
  binding uses `email`), `to` string / object / array (to+cc+bcc max 50),
  `subject` (max 998 chars), `html` and/or `text`, optional `reply_to`,
  `headers` (allowlist + `X-*`; a disallowed header rejects the request),
  `attachments`. Message max 5 MiB.
- Success: `{success: true, errors: [], messages: [], result: {delivered: [],
  queued: [], permanent_bounces: [], suppressed_recipients?: [], message_id}}`.
  The narrative page omits `message_id`; the schema has it. Verify once.
- Error: `{success: false, errors: [{code, message}], messages: [], result: null}`.
  400: 10001 invalid_request_schema, 10200 email.too_big, 10202 email.invalid.
  401: 10101 unauthorized, 10103 bad_token_type. 403: 10102 forbidden,
  10105 not_entitled, 10203 email.sending_disabled, 10207 account_suspended.
  404: 10000. 429: 10004 throttled. 500: 10002, 10003. 503: 10100 upstream.
- A suppressed recipient fails the whole request with 400 unless
  `drop_suppressed_recipients` is on for the sending subdomain.
- `send_raw` variant takes a full MIME message; not needed.

## Quotas and limits

- Workers Paid: 3,000 emails per account per month included, $0.35 per
  1,000 beyond. Rejected and suppressed sends do not count; hard bounces do.
- Daily quota for new accounts is "conservative", unpublished, grows over
  time; a limit increase form exists. No per-second figure published. Rate
  limits are checked per account, domain and recipient; over-limit requests
  are rejected (429 10004) and must be retried later.

## Prerequisites

- Cloudflare DNS for the zone (stxr.io / structure.fi are on Cloudflare).
- Arbitrary recipients need Workers Paid. Before a sending domain is
  onboarded, only verified destination addresses (Email Routing >
  Destination Addresses) can receive mail.
- The `from` must belong to an onboarded sending domain; subdomains are
  onboarded separately, and `notifications.<domain>` is the documented
  recommendation for transactional mail. Onboarding creates MX, SPF and
  DKIM on `cf-bounce.<domain>` and DMARC on `_dmarc.<domain>`. No CNAME.
- API: `POST /zones/{zone_id}/email/sending/subdomains {name}` and
  `GET .../subdomains/{id}/dns` for the expected records.

## Not offered

- No hosted templates. No HTTP webhooks: delivery events go to a Cloudflare
  Queue per sending domain (`cf.email.sending.message.{delivered, deferred,
  bounced, failed, rejected, complained}`), consumed by a Worker or an HTTP
  pull consumer. No idempotency key; `Message-ID` is platform generated.
- Bounces and complaints feed an account suppression list with REST CRUD.

## Pulumi

- `@pulumi/cloudflare` 6.23.2 has `cloudflare.EmailSendingSubdomain`
  (inputs `zoneId`, `name`, `dropSuppressedRecipients`, `previewEnabled`;
  outputs `tag`, `enabled`, `dkimSelector`, `returnPathDomain`). Whether it
  also publishes the DNS records is not documented; the `dns` endpoint
  returns the expected records, so verify after the first `up`.
- No resource for the account-level send side.
