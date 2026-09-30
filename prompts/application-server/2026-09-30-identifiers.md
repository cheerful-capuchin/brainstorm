## Context
- ensure there is a session file created (see the decision-log skill)

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


