#!/usr/bin/env bash
# Compare the GitHub hook ranges in charts/values.yaml with api.github.com/meta (.hooks).
# On a difference: rewrite the list, raise the patch version, open a PR and start CI on the branch.
# Usage: scripts/github-hooks.sh   (run from the repository root; gh uses GH_TOKEN)
# Env: DRY_RUN=1          print the diff and the commands only; change nothing
#      HOOKS_TICKET_KEY   Jira key for the branch name (default DEVSECOPS-32)
# Test hooks (offline): META_FILE=<json file> replaces the API call; META_URL=<url> replaces the API URL.
set -euo pipefail

META_URL=${META_URL:-https://api.github.com/meta}
VALUES=charts/values.yaml
CHART=charts/Chart.yaml
KEY=${HOOKS_TICKET_KEY:-DEVSECOPS-32}
DRY_RUN=${DRY_RUN:-0}
RANGE_COMMENT='Accept this public GitHub hook range.'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [[ -n ${META_FILE:-} ]]; then
  cp "$META_FILE" "$work/meta.json"
else
  curl -fsSL --max-time 30 --retry 2 -o "$work/meta.json" "$META_URL"
fi

# Fail closed: .hooks must be a non-empty array of strings.
if ! jq -e '(.hooks | type == "array" and length > 0 and all(.[]; type == "string"))' "$work/meta.json" >/dev/null 2>&1; then
  echo '::error::The GitHub meta response has no valid .hooks list. Nothing changed.' >&2
  exit 1
fi

jq -r '.hooks[]' "$work/meta.json" | sort >"$work/new.txt"
yq '.webhookRoute.githubHookSourceRanges[]' "$VALUES" | sort >"$work/old.txt"

if cmp -s "$work/old.txt" "$work/new.txt"; then
  echo "no change: $(wc -l <"$work/new.txt" | tr -d ' ') GitHub hook ranges are current."
  exit 0
fi

# Work on copies in a dry run so the tree stays untouched.
if [[ "$DRY_RUN" == 1 ]]; then
  cp "$VALUES" "$work/values.yaml"
  cp "$CHART" "$work/Chart.yaml"
  TARGET_VALUES="$work/values.yaml"
  TARGET_CHART="$work/Chart.yaml"
else
  TARGET_VALUES="$VALUES"
  TARGET_CHART="$CHART"
fi

# The list is rewritten in the same order as GitHub sends it. The key comment stays.
RANGES=$(jq -c '.hooks' "$work/meta.json") yq -i \
  ".webhookRoute.githubHookSourceRanges = (strenv(RANGES) | from_json) | .webhookRoute.githubHookSourceRanges style = \"\" | .webhookRoute.githubHookSourceRanges[] style = \"\" | .webhookRoute.githubHookSourceRanges[] line_comment = \"$RANGE_COMMENT\"" \
  "$TARGET_VALUES"

OLD_VERSION=$(yq '.version' "$CHART")
if ! [[ "$OLD_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo '::error::Version in charts/Chart.yaml must be X.Y.Z.' >&2
  exit 1
fi
NEW_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
sed -E "s/^version: .*/version: $NEW_VERSION/" "$TARGET_CHART" >"$work/Chart.new"
cat "$work/Chart.new" >"$TARGET_CHART"

BRANCH="bugfix/$KEY-github-hook-ranges-$(date +%Y%m%d)"
TITLE="$KEY: refresh GitHub hook ranges"
BODY="api.github.com/meta .hooks differs from webhookRoute.githubHookSourceRanges. Chart version $OLD_VERSION -> $NEW_VERSION. CI starts by workflow_dispatch on this branch."

if [[ "$DRY_RUN" == 1 ]]; then
  echo "dry run: the changes below are NOT written to the repository."
  diff -u "$VALUES" "$work/values.yaml" || true
  diff -u "$CHART" "$work/Chart.yaml" || true
  printf 'would run: %s\n' \
    "git checkout -b $BRANCH" \
    "git add $VALUES $CHART" \
    "git commit -m 'fix(chart): refresh GitHub hook ranges'" \
    "git push origin $BRANCH" \
    "gh pr create --base main --head $BRANCH --title '$TITLE' --body '$BODY'" \
    "gh workflow run main.yaml --ref \"$BRANCH\""
  exit 0
fi

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git checkout -b "$BRANCH"
git add "$VALUES" "$CHART"
git commit -m 'fix(chart): refresh GitHub hook ranges'
git push origin "$BRANCH"
gh pr create --base main --head "$BRANCH" --title "$TITLE" --body "$BODY"
# A push made with GITHUB_TOKEN starts no workflow. workflow_dispatch is exempt.
gh workflow run main.yaml --ref "$BRANCH"
