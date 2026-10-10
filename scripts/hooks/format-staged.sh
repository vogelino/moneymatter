#!/bin/sh
set -eu

# Only fully staged files are formatted and re-staged. A partially staged file
# is left alone so hunks kept out with `git add -p` stay out of the commit.
unstaged=$(mktemp)
trap 'rm -f "$unstaged"' EXIT HUP INT TERM

git diff --name-only > "$unstaged"
fully_staged=$(git diff --cached --name-only --diff-filter=ACMR | grep -vxF -f "$unstaged" || true)

if [ -n "$fully_staged" ]; then
  printf '%s\n' "$fully_staged" | tr '\n' '\0' | xargs -0 npx --no-install oxfmt --no-error-on-unmatched-pattern
  printf '%s\n' "$fully_staged" | tr '\n' '\0' | xargs -0 git add
fi

if printf '%s\n' "$fully_staged" | grep -qE '^packages/frontend/public/(skills/|\.well-known/agent-skills/index\.json)'; then
  node scripts/regen-agent-skills-index.mjs
  git add packages/frontend/public/.well-known/agent-skills/index.json
fi
