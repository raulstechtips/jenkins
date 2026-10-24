#!/usr/bin/env bash
# Version for the manual GitHub Actions backup build. Jenkins makes the real versions.
# Base is the version in charts/Chart.yaml with the patch number raised by one. No network call.
set -euo pipefail

BRANCH_RE='^(feature|bugfix|hotfix|release)/([A-Z][A-Z0-9]*-[0-9]+)(-.*)?$'
if [[ "$GITHUB_REF_NAME" == main ]]; then
  TYPE=main
elif [[ "$GITHUB_REF_NAME" =~ $BRANCH_RE ]]; then
  TYPE="${BASH_REMATCH[1]}-${BASH_REMATCH[2],,}"
else
  printf '::error::Branch "%s" must be <type>/<KEY>-<number>[-text]. The type must be feature, bugfix, hotfix or release. Example: feature/DEVSECOPS-54-jenkins-chart.\n' "$GITHUB_REF_NAME"
  exit 1
fi

CHART_VERSION=$(yq '.version' charts/Chart.yaml)
if ! [[ "$CHART_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo '::error::Version in charts/Chart.yaml must be X.Y.Z.'
  exit 1
fi
IFS=. read -r MAJOR MINOR PATCH <<<"$CHART_VERSION"
VERSION="${MAJOR}.${MINOR}.$((10#$PATCH + 1))-${TYPE}-${GITHUB_SHA::7}-${GITHUB_RUN_NUMBER}"

echo "VERSION=$VERSION"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  echo "version=$VERSION" >> "$GITHUB_OUTPUT"
fi
