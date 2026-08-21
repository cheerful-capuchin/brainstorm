# RustRover GitHub plugin — submodule repositories missing from Pull Requests

Date: 2026-08-19

## Symptom

The GitHub plugin's Pull Requests tool window offered only two repositories in
its selector:

- `cheerful-capuchin/stxr-mono origin` (the superproject)
- `drift-labs/drift-ffi-sys origin` (an unrelated third-party dependency)

None of the ~82 submodules that make up the workspace appeared, so their PRs
could not be reviewed from the IDE.

The initial question was whether this was a JetBrains bug or a local
misconfiguration. It turned out to be **two independent failures stacked on top
of each other**, which is why the first fix appeared to do nothing.

## Environment

- RustRover 2026.1, single GitHub account registered (`cheerful-capuchin`,
  server `github.com`)
- Workspace: git superproject with 82 submodules, several nested
- 90 VCS directory mappings in `.idea/vcs.xml`, all resolving to valid git roots

## Root cause

### Layer 1 — repository discovery (URL host not recognised)

Every submodule remote used an SSH host alias:

```text
ssh://git@github-work/stxr-prop/<repo>
```

`github-work` is an alias defined in `~/.ssh/config` (`HostName github.com`
with a specific `IdentityFile`). The GitHub plugin resolves remotes by matching
the URL host against known GitHub servers, and it does **not** read
`~/.ssh/config`. It sees the literal string `github-work`, fails to match it to
`github.com`, and silently drops the root.

This is a known, long-standing JetBrains limitation, not a local mistake.

The two repositories that did appear were the only two roots whose remote
contained a literal `github.com`:

| Root | Remote URL | Listed |
|---|---|---|
| `stxr-mono` | `git@github.com:cheerful-capuchin/stxr-mono.git` | yes |
| `drift-types/drift-rs/crates/drift-ffi-sys` | `https://github.com/drift-labs/drift-ffi-sys` | yes |
| all 82 submodules | `ssh://git@github-work/stxr-prop/...` | no |

**URL format also matters.** Rewriting the host alone was not sufficient. A
scheme-style URL:

```text
ssh://git@github.com/stxr-prop/dsl-processor-core
```

was still not listed. Only the scp-style form was picked up:

```text
git@github.com:stxr-prop/dsl-processor-core.git
```

That matches the format of `stxr-mono`, the root that already worked. The
distinction cost one debugging round-trip and is the single most important
detail to carry forward.

### Layer 2 — API access (token lacks private-repo visibility)

Once the repository was discoverable, the plugin reported:

```text
Could not connect to repository github.com/stxr-prop/dsl-processor-core
with account github.com/cheerful-capuchin
Could not resolve to a Repository with the name 'stxr-prop/dsl-processor-core'
```

`Could not resolve to a Repository` is GraphQL's 404-equivalent. GitHub does not
return a 403 for a private repository the token cannot see — it reports the
repository as non-existent. The IDE's stored credential lacked private-repo
visibility.

The fix was to re-authenticate the IDE account with a **classic personal access
token** carrying `repo` and `read:org`. This also sidesteps organisation
third-party OAuth application restrictions, which classic PATs are not subject
to — relevant here because the account is an org `member`, not an `owner`, and
could not have approved the JetBrains OAuth app itself.

## How the hypotheses were eliminated

| Hypothesis | Evidence | Verdict |
|---|---|---|
| VCS roots not registered | all 90 mappings in `.idea/vcs.xml` resolve to valid git roots | ruled out |
| Wrong or missing IDE account | `options/github.xml` shows exactly one account, `cheerful-capuchin` on `github.com` | ruled out |
| SSH transport broken | `git ls-remote` returned `9c1e7958` after each rewrite | ruled out |
| Work SSH key belongs to a different GitHub user | `ssh -T git@github-work` → `Hi cheerful-capuchin!` | ruled out |
| Account genuinely lacks org access | `gh api /repos/stxr-prop/dsl-processor-core` → `200 OK` | ruled out |
| SAML SSO not authorised for the token | response carried no `X-GitHub-SSO` challenge | ruled out |
| Remote URL host/format not matched by plugin | only non-`ssh://` github.com roots were listed | **confirmed** |
| IDE token lacks `repo` scope / org app approval | `gh` token with `repo` works; IDE token does not | **confirmed** |

`GIT_TRACE=1` was the decisive tool for the transport half. It shows the host
git actually dials after `insteadOf` rewriting, which distinguishes a real pass
from an accidental fallback to a different key:

```text
trace: run_command: ... ssh ... git@github-work 'git-upload-pack /stxr-prop/dsl-processor-core'
```

## Fix applied

Only one submodule was converted, as a probe. It is confirmed working
end-to-end — the repository is listed and its pull requests load.

```sh
git -C dsl-processor-core remote set-url origin \
    git@github.com:stxr-prop/dsl-processor-core.git
```

Plus, in the IDE: **Settings → Version Control → GitHub** → remove the existing
account → **Add account → Log In with Token** → paste a classic PAT with `repo`
and `read:org`.

The token is account-wide, so layer 2 is now solved for every repository. Only
layer 1 remains per-repository.

## Remaining work

Convert the other 81 submodules. This rewrites each submodule's local
`.git/config` only; `.gitmodules` is left untouched:

```sh
git submodule foreach --recursive 'url=$(git remote get-url origin); case "$url" in ssh://git@github-work/*) p=${url#ssh://git@github-work/}; git remote set-url origin "git@github.com:${p%.git}.git";; esac'
```

Verify — this should print nothing:

```sh
git submodule foreach --quiet --recursive 'git remote get-url origin' | grep github-work
```

Two follow-up decisions:

1. **`git submodule sync` reverts the change.** It copies URLs from
   `.gitmodules` back into each `.git/config`. To make the fix durable,
   `.gitmodules` needs the same rewrite. That file is tracked and shared, so it
   is a deliberate call rather than a local convenience.
2. **The dropdown will hold ~84 entries.** The plugin keeps a separate PR list
   per repository. If that becomes unwieldy, prune the roots that are never
   reviewed from Settings → Version Control → Directory Mappings.

## Incidental findings

**The `github-work` alias is redundant for this account.** All three SSH hosts
were probed:

```text
github.com       → Hi cheerful-capuchin!
github-work      → Hi cheerful-capuchin!
github-personal  → Hi <separate personal account>!
```

`github-work` and the default `github.com` entry authenticate as the *same*
GitHub user with different keys. Since identity — not key — determines repository
permissions, the alias grants no access that the default entry does not already
grant for `stxr-prop`. It contributed nothing except breaking IDE integration.

**Two `insteadOf` rules exist in the global git config** mapping
`ssh://git@github.com/{stxr-prop,cheerful-capuchin}/` onto the `github-work`
alias. They never fired, because stored URLs were already in the rewritten form.
With scp-style canonical URLs in place they remain inert and are candidates for
removal.

**Org distribution in `.gitmodules`:** `stxr-prop` ×81, `cheerful-capuchin` ×1.

## Transferable lessons

1. A plugin silently omitting something is a *discovery* failure; an explicit
   error is an *authorisation* failure. They are different layers and can mask
   one another. Fixing the first makes the second visible, which reads as "the
   fix did nothing" if you are not expecting it.
2. Git transport credentials (SSH keys) and GitHub API credentials (tokens) are
   independent. A repository can clone and fetch perfectly while the IDE cannot
   see it at all.
3. GitHub reports invisible private repositories as non-existent. Treat
   `Could not resolve to a Repository` as a permissions signal, never as a typo.
4. When comparing a broken case against a working one, match the working case
   exactly — host *and* URL format. Partial imitation produced a false negative
   here.

## References

- [IDEA-325806 — Support SSH aliases](https://youtrack.jetbrains.com/issue/IDEA-325806/Support-SSH-aliases)
- [IDEA-276812 — Pull request menu does not work with multiple github ssh identities](https://youtrack.jetbrains.com/issue/IDEA-276812)
- [IJPL-72809 — Github with multiple accounts: support ssh alias](https://youtrack.jetbrains.com/projects/IJPL/issues/IJPL-72809/Github-with-multiple-accounts-support-ssh-alias)
- [SUPPORT-A-2404 — Cannot access GitHub repository in Pull Requests tab](https://youtrack.jetbrains.com/articles/SUPPORT-A-2404/Cannot-access-GitHub-repository-in-Pull-Requests-tab)
