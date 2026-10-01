## Context
- session file: `brainstorm/sessions/SESS-00PH0TQ-email-otp-auth-whitelist-internal-access.md` (see the decision-log skill)

We want to add a new authentication method to our application - email with OTP sent to your email account.
I've already envisioned the iam-core/ts/src/entities/identifier/identifier.ts entity that includes different kinds of identifiers.
We can, easily, put email as one of the kinds.

Then, we need to expand our structure-web/packages/api/src/auth/auth-service.ts to handle the sign in with email.
And fix our whitelist from
```
let existingDeposit = args.config.creditDeposits.get(trustedIdentifier.value.value);
if (!existingDeposit || !Credit.isActivated(existingDeposit)) {
    return err(Auth.NewDepositRequiredError(trustedIdentifier.value.value));
}
```

to a proper whitelist that includes the identifiers, not pubkeys.

This all seems quite trivial, except the email sending part.
How is the "OTP" generated? I guess we can take inspiration from https://github.com/anomalyco/openauth, which I downloaded into ~/work/gh/openauth.
We're using GCP in infra/infra. How do you send emails? Does Google have an API/Service, like AWS, or do I need to use something external?


### Whitelist
We should remove the whilelist from the YAML config and instead have it be maintained in the database and add some endpoints to do that.

### Internal Access
How do we manage the internal access to modify the whitelist? Ideally, with audit logs.
The lazy option is to have the api key and use that. However, it's a very unstable solution.

How would you manage the permissions within the structure platform and have a set of accounts that are allowed to modify it?
I was thinking of introducing the hierarchy like Organization and then have users have memberships in the organizations.
We could reserve the structure org id and use that id as the org that has full access to the platform and can modify the whilelists, settings, start jobs, etc

## Q&A

### Which service to use for sending the Emails?
Cloudflare Email Service looks promising and we already have infra there.
Google Cloud has no service of its own.
Options: Google Workspace relay, AWS SES, SendGrid, Mailgun, Mailjet, Postmark.

