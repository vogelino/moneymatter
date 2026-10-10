# Security Policy

## Reporting a vulnerability

**Do not open a public issue for security problems.**

Report privately through GitHub's advisory form:
https://github.com/letehaha/moneymatter/security/advisories/new

Please include:

- What the issue is and its impact
- Where it happened: `moneymatter.app` or a self-hosted instance (with the image
  tag or the "App version" shown in the sidebar)
- Steps to reproduce, or a proof of concept

You will get an acknowledgement within 7 days. MoneyMatter is maintained by one
person, so fixes are best effort, but confirmed issues are treated as top
priority. You will be credited in the advisory unless you ask otherwise.

## Secret leak prevention

The repository uses Gitleaks at three points:

- Lefthook scans staged content before each commit.
- Lefthook scans all reachable local history before each push.
- GitHub Actions scans complete repository history on every pull request and push.

Run `npm install` after cloning to install the hooks. Run
`npm run security:secrets:history` to scan manually. The first scan downloads a
pinned Gitleaks binary and verifies its SHA-256 digest before executing it.

Local hooks are a fast safety net, not a trust boundary: Git allows them to be
bypassed. Protect `main` and other release branches by requiring the **Gitleaks
(complete history)** status check, disallowing force pushes, and requiring pull
requests. Enable GitHub secret scanning and push protection for the repository
as an independent provider-aware control.

If a credential is detected or suspected, do not merely delete it in a later
commit. Revoke or rotate it immediately, check provider and audit logs for use,
remove it from Git history if exposure warrants rewriting history, and notify
affected operators. Treat any committed credential as compromised even if the
push was rejected.

Exceptions must be fingerprint-specific entries in `.gitleaksignore`, with a
comment explaining why the finding cannot be a live secret. Broad path or rule
exclusions are not accepted.

If you used an AI tool to find the issue, say so and make sure you have
reproduced it yourself against a real instance before reporting.

## Scope

- The hosted service at `moneymatter.app`
- The published Docker images `letehaha/budget-tracker-be` and
  `letehaha/budget-tracker-fe`
- This repository's source code

Out of scope:

- Misconfiguration of a self-hosted deployment (exposed database or Redis
  ports, weak `.env` secrets, reverse-proxy setup)
- Vulnerabilities in third-party services the app connects to (bank data
  providers, AI providers, Crowdin)
- Denial of service, rate limiting, or missing security headers without a
  demonstrated impact

## Supported versions

Only the latest release and the `latest` Docker images receive security fixes.
Self-hosters should stay on a recent release.
