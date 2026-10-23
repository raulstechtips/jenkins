#!/usr/bin/env bash
set -euo pipefail

# Run after helm dependency build charts and docker build. No image is pulled.
if [[ $# != 1 ]]; then
  echo "Usage: bash tests/integration/controller/run.sh IMAGE" >&2
  exit 2
fi
IMAGE=$1
FIXTURES=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$FIXTURES/../../.." && pwd)
for tool in docker helm yq; do
  command -v "$tool" >/dev/null || { echo "Required tool: $tool" >&2; exit 1; }
done
docker image inspect "$IMAGE" >/dev/null
WORK=$(mktemp -d)
NAME="controller-image-test-$$"
VOLUME="$NAME-home"
CONTAINER=
ATTACH_PID=

cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$CONTAINER" ]]; then
    if [[ $status != 0 ]]; then
      docker logs "$CONTAINER" >&2 || true
    fi
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ -n "$ATTACH_PID" ]]; then
    wait "$ATTACH_PID" 2>/dev/null || true
  fi
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$WORK/casc" "$WORK/secrets"
helm template jenkins "$ROOT/charts" -n jenkins \
  -f "$FIXTURES/values.yaml" > "$WORK/rendered.yaml"
# Use the generated init script, not a test copy of the overwrite logic.
yq -r 'select(.kind == "ConfigMap" and .data."apply_config.sh" != null) |
  .data."apply_config.sh"' "$WORK/rendered.yaml" > "$WORK/apply_config.sh"
test -s "$WORK/apply_config.sh"
grep -Fq 'rm -rf /var/jenkins_home/plugins/*' "$WORK/apply_config.sh"
if grep -Eq 'jenkins-plugin-cli|install-plugins.sh' "$WORK/apply_config.sh"; then
  echo "The rendered chart must disable plugin downloads." >&2
  exit 1
fi
yq -r 'select(.kind == "ConfigMap") | .data | to_entries |
  .[] | select(.key | test("\\.yaml$")) | .key' "$WORK/rendered.yaml" \
  > "$WORK/config-keys"
while IFS= read -r key; do
  KEY="$key" yq -r 'select(.kind == "ConfigMap" and .data[strenv(KEY)] != null) |
    .data[strenv(KEY)]' "$WORK/rendered.yaml" > "$WORK/casc/$key"
done < "$WORK/config-keys"
for config in security github libraries jobs jcasc-default-config; do
  test -s "$WORK/casc/$config.yaml"
done
cp "$ROOT/plugins/plugins.txt" "$WORK/plugins.txt"
cp "$ROOT/plugins/plugins.lock.txt" "$WORK/plugins.lock.txt"
cp "$FIXTURES/assert.groovy" "$WORK/assert.groovy"
printf '%s' controller-test-admin > "$WORK/secrets/chart-admin-username"
printf '%s' controller-test-password > "$WORK/secrets/chart-admin-password"
printf '%s' 12345 > "$WORK/secrets/jenkins-github-appId"
printf '%s' mock-private-key-not-for-authentication > "$WORK/secrets/jenkins-github-privateKey"
printf '%s' mock-webhook-secret > "$WORK/secrets/jenkins-github-webhookSecret"
chmod -R a+rX "$WORK"
docker volume create "$VOLUME" >/dev/null

start_and_check() {
  local phase=$1 line remaining deadline
  echo "Testing $phase home"
  # This is the same init command and home volume used by the chart.
  docker run --rm --pull never --network none \
    --mount "type=volume,src=$VOLUME,dst=/var/jenkins_home" \
    --mount "type=bind,src=$WORK,dst=/test,readonly" \
    --entrypoint sh "$IMAGE" /test/apply_config.sh
  CONTAINER=$(docker create --pull never --network none \
    --name "$NAME-$phase" \
    --mount "type=volume,src=$VOLUME,dst=/var/jenkins_home" \
    --mount "type=bind,src=$WORK,dst=/test,readonly" \
    -e CASC_JENKINS_CONFIG=/test/casc -e SECRETS=/test/secrets \
    -e JAVA_OPTS="-Djenkins.install.runSetupWizard=false" "$IMAGE")
  mkfifo "$WORK/startup-$phase"
  # Docker start --attach attaches stdout/stderr before it starts the process.
  # Keep one FIFO descriptor open so an early process exit is also bounded.
  exec 3<>"$WORK/startup-$phase"
  docker start --attach "$CONTAINER" > "$WORK/startup-$phase" 2>&1 &
  ATTACH_PID=$!
  deadline=$((SECONDS + 240))
  while true; do
    remaining=$((deadline - SECONDS))
    if (( remaining <= 0 )) || ! IFS= read -r -t "$remaining" line <&3; then
      echo "Controller did not complete startup within 240 seconds ($phase)." >&2
      return 1
    fi
    printf '%s\n' "$line"
    if [[ "$line" == *"Jenkins is fully up and running" ]]; then
      break
    fi
  done
  # Use the image's curl, after the lifecycle signal, with no retries.
  if ! docker exec "$CONTAINER" bash -euc '
    url=http://127.0.0.1:8080
    auth=controller-test-admin:controller-test-password
    curl -fsS --max-time 30 -u "$auth" "$url/login" >/dev/null
    xml=$(curl --fail-with-body -sS --max-time 30 -u "$auth" -c /tmp/test-cookies \
      "$url/crumbIssuer/api/xml")
    field=${xml#*"<crumbRequestField>"}
    field=${field%%"</crumbRequestField>"*}
    crumb=${xml#*"<crumb>"}
    crumb=${crumb%%"</crumb>"*}
    test -n "$field"
    test -n "$crumb"
    curl --fail-with-body -sS --max-time 60 -u "$auth" -b /tmp/test-cookies -H "$field:$crumb" \
      --data-urlencode script@/test/assert.groovy "$url/scriptText"
  ' > "$WORK/assertions-$phase"; then
    cat "$WORK/assertions-$phase" >&2
    return 1
  fi
  cat "$WORK/assertions-$phase"
  grep -Fxq 'CONTROLLER_IMAGE_TEST_OK' "$WORK/assertions-$phase"
  docker stop --time 20 "$CONTAINER" >/dev/null
  # Jenkins exits with 128 + SIGTERM after docker stop.
  wait "$ATTACH_PID" || test "$?" -eq 143
  ATTACH_PID=
  exec 3>&-
  docker rm "$CONTAINER" >/dev/null
  CONTAINER=
}

start_and_check fresh
# Corrupt a real pinned archive, leave its expanded directory and version marker,
# and add an unknown plugin. The rendered init script must remove all of them.
docker run --rm --pull never --network none \
  --mount "type=volume,src=$VOLUME,dst=/var/jenkins_home" \
  --entrypoint bash "$IMAGE" -euc '
    test -s "$JENKINS_HOME/plugins/git.jpi"
    printf stale-archive > "$JENKINS_HOME/plugins/git.jpi"
    printf 999999 > "$JENKINS_HOME/plugins/git.jpi.version_from_image"
    mkdir -p "$JENKINS_HOME/plugins/git"
    printf stale-expanded-plugin > "$JENKINS_HOME/plugins/git/stale-test-marker"
    printf stale-unknown-plugin > "$JENKINS_HOME/plugins/stale-controller-test.jpi"
  '
start_and_check reused
echo "Controller image passed fresh-home and reused-home tests."
