#!/usr/bin/env bash
# Adds the shared Biome setup to a repo. Run from the repo root on a clean branch.
#   bash setup.sh
# Produces three commits: setup, one-time autofix, ratchet (remaining errors downgraded to warn).
set -euo pipefail
export NO_COLOR=1

BIOME_VERSION="2.5.15"
CONFIG_REF="github:aplfme/lint-config#v1"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -f package.json ] || { echo "no package.json" >&2; exit 1; }

if [ -f pnpm-lock.yaml ]; then PM=pnpm; ADD="pnpm add -D -E"; RM="pnpm remove"
elif [ -f yarn.lock ]; then PM=yarn; ADD="yarn add -D -E"; RM="yarn remove"
else PM=npm; ADD="npm install -D -E"; RM="npm uninstall"
fi

# 1. Replace ESLint/Prettier with Biome
rm -f eslint.config.* .eslintrc .eslintrc.* .eslintignore .prettierrc .prettierrc.* prettier.config.* .prettierignore
OLD=$(node -e '
  const p = require("./package.json");
  const deps = { ...p.dependencies, ...p.devDependencies };
  console.log(Object.keys(deps).filter(d =>
    /^(eslint|prettier|typescript-eslint|eslint-config-.*|eslint-plugin-.*|@eslint\/.*|@typescript-eslint\/.*|@next\/eslint-plugin-next|prettier-plugin-.*)$/.test(d)
  ).join(" "));
')
[ -n "$OLD" ] && $RM $OLD

$ADD "@biomejs/biome@$BIOME_VERSION" lefthook "@aplfme/lint-config@$CONFIG_REF"

cat > biome.json <<EOF
{
  "\$schema": "https://biomejs.dev/schemas/$BIOME_VERSION/schema.json",
  "root": true,
  "extends": ["@aplfme/lint-config/biome"]
}
EOF

npm pkg set scripts.lint="biome check ." scripts.lint:fix="biome check --write ." scripts.format="biome format --write ."
# lefthook's npm package installs the git hooks on postinstall; keep it explicit for pnpm (which skips postinstall of deps by default)
npm pkg set scripts.prepare="lefthook install || true"

cp "$HERE/templates/lefthook.yml" lefthook.yml
mkdir -p .github/workflows
DEFAULT_BRANCH=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||' || echo main)
sed "s/__DEFAULT_BRANCH__/$DEFAULT_BRANCH/" "$HERE/templates/lint.yml" > .github/workflows/lint.yml

git add -A
git commit -q --no-verify -m "chore: add Biome linter and formatter

Replaces ESLint/Prettier with the shared config from aplfme/lint-config.
Adds a lefthook pre-commit hook and a Lint CI workflow."

# 2. One-time autofix (safe fixes + format + import sorting)
npx biome check --write --max-diagnostics=0 . >/dev/null 2>&1 || true
if ! git diff --quiet; then
  git add -A
  git commit -q --no-verify -m "chore: apply Biome autofix and formatting

Mechanical change only. Listed in .git-blame-ignore-revs."
  echo "$(git rev-parse HEAD) # Biome autofix and formatting" >> .git-blame-ignore-revs
fi

# 3. Ratchet: downgrade every rule that still errors to warn, so CI starts green
npx biome lint --reporter=json --max-diagnostics=none . 2>/dev/null > /tmp/biome-$$.json || true
node "$HERE/ratchet.mjs" /tmp/biome-$$.json biome.json
rm -f /tmp/biome-$$.json
npx biome format --write biome.json >/dev/null 2>&1 || true

npx biome ci . >/dev/null 2>&1 || { echo "biome ci still failing after ratchet:" >&2; npx biome ci . 2>&1 | tail -40 >&2; exit 2; }

git add -A
git commit -q --no-verify -m "chore: set existing Biome violations to warn

Each rule listed in biome.json still has violations in this repo.
Fix them, then remove the override so the rule goes back to error." || true
echo "done ($PM)"
