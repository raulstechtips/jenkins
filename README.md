# jenkins

This repository contains the Helm chart that installs Jenkins in the cluster.

## 1. Purpose

The chart wraps the upstream `jenkins` Helm chart `5.9.73` (Jenkins `2.580.1`) as a dependency.
The chart also adds our own resources: Infisical secrets, Keycloak OIDC login, Traefik IngressRoutes, deployer RBAC and JCasC configuration.
All Jenkins configuration comes from Git. You do not configure Jenkins in the UI.
Each successful push build publishes a controller image and a matching chart version to GHCR.
The chart pins the controller image by digest. Change only the chart version to deploy the pair.
Argo CD then installs the chart from this OCI address, with values from the `cluster-config` repository:

```
oci://ghcr.io/raulstechtips/charts/jenkins
```

## 2. Repository layout

| Path | Contents |
| --- | --- |
| `plugins/` | `Dockerfile`, `plugins.txt` (the plugins we choose, pinned), `plugins.lock.txt` (generated: those pins and all dependencies) and `lock.sh` (makes the lock). |
| `charts/` | The Helm chart. `Chart.yaml`, `Chart.lock`, `values.yaml` and `values.schema.json`. |
| `charts/templates/` | Our own templates: Infisical secrets, IngressRoutes, the GitHub allowlist Middleware, deployer RBAC and JCasC ConfigMaps. |
| `charts/tests/` | The helm-unittest unit tests (`*_test.yaml`). They check the rendered templates only. |
| `tests/integration/controller/` | The integration test for the controller image and the chart together. `run.sh` renders the chart with `values.yaml`, runs the chart's init script, starts the image with no network and runs `assert.groovy` in Jenkins. |
| `charts/ci/` | Values files for CI. `all-on-values.yaml` turns on all features with fake values. |
| `.github/workflows/` | `main.yaml` is the pipeline. It calls `test.yaml`, then `scan.yaml`, then `release.yaml`. `retention.yaml` deletes old branch versions. `github-hooks.yaml` refreshes the GitHub hook ranges each week. |
| `scripts/` | Shell scripts for the workflows: `version.sh`, `retention.sh` and `github-hooks.sh`. |

## 3. How CI works

The pipeline has three steps:

1. **Test.** Helm lint, helm-unittest, `helm template` and kubeconform. Build the controller image for amd64 only, because the cluster runs only amd64 nodes. Start the image without external networking, with fresh and reused Jenkins home volumes, and check its plugins and JCasC. A check also stops the run if a file contains a private key.
2. **Scan.** Security scans of the rendered chart and the tested amd64 controller image.
3. **Publish.** Make the release version, push the tested amd64 image, then package and publish the chart with `image.tag` set to `<version>@<digest>`. No chart is published unless its controller image was published first.

### Branch rule

The workflow runs for pushes to `main` and to branches that start with `feature/`, `bugfix/`, `hotfix/` or `release/`.
You can also start it manually (`workflow_dispatch`).
The `github-hooks` workflow starts it this way after it opens a range-update PR, because a branch that `GITHUB_TOKEN` pushes starts no `push` run.
Each branch other than `main` must match this regular expression:

```
^(feature|bugfix|hotfix|release)/([A-Z][A-Z0-9]*-[0-9]+)(-.*)?$
```

The format is `<type>/<KEY>-<number>[-text]`. Example: `feature/DEVSECOPS-32-jenkins-chart`.
If the name is bad, the `version` job fails and tells you the correct format.

### Version format

The workflow makes the shared image and chart version. Do not write it into git.

| Branch | Format | Example |
| --- | --- | --- |
| `main` | `X.Y.Z-main-<sha7>-<run#>` | `1.0.0-main-abc1234-15` |
| Other branch | `X.Y.Z-<type>-<lowercase key>-<sha7>-<run#>` | `1.0.0-feature-devsecops-32-abc1234-12` |

`X.Y.Z` is the `version` in `charts/Chart.yaml`.

### Retention

The `retention` workflow deletes branch versions that are older than 7 days.
It keeps all `main` versions.
For a long-lived install, use a `main` version.
Controller images are retained because existing charts reference their digests.

### Weekly GitHub hook ranges

The `github-hooks` workflow runs each week.
It compares GitHub meta `.hooks` ranges with `webhookRoute.githubHookSourceRanges`.
If the lists are different, it updates the list, raises the patch version, opens a PR and starts CI on that branch.

## 4. Values layout

The values file has two parts.

1. Upstream values go under the `jenkins:` key. The upstream chart reads them.
2. Our own resources are top-level keys. All are off or empty by default.

| Key | Default | Purpose |
| --- | --- | --- |
| `infisical` | empty `authRef`, `projectSlug`, `environmentSlug` and `push` | The Infisical connection. Pulls use `authRef`. The escape-hatch push uses `push.hostAPI` and `push.credentialsRef`. |
| `oidc` | `enabled: false` | Keycloak login with PKCE. Set `oidc.issuer` to the Keycloak realm URL `<issuer>`. Groups `jenkins-admins` and `jenkins-users`. |
| `github` | `enabled: false` | The GitHub App credential (`github-app`) and the webhook secret, from `/jenkins/github`. |
| `escapeHatch` | `pushToInfisical: false` | Copies the break-glass admin password to Infisical `/jenkins/admin`. |
| `additionalSecrets` | `[]` | More Infisical secrets. Each entry can become a Jenkins credential, for example a `secretFile` kubeconfig for another cluster. |
| `uiRoute` | `enabled: false` | The IngressRoute for the Jenkins UI on `<ui-host>`. |
| `webhookRoute` | `enabled: false` | The IngressRoute for `/github-webhook/` only on `<webhook-host>`, behind the GitHub allowlist. `githubHookSourceRanges` holds the GitHub meta `.hooks` ranges (chart default, refreshed each week). `additionalHookSourceRanges` (`[]`) adds more ranges. `ipStrategyDepth` (`0`) tells Traefik which IP to check: `0` uses the connection source IP. Set `1` when exactly one trusted proxy, such as Cloudflare, is in front. |
| `deployNamespaces` | `[]` | One `jenkins-deployer` RoleBinding (ClusterRole `admin`) for each namespace in the list. |
| `sharedLibraries` | `[]` | Pipeline libraries: `{name, repo, defaultVersion?}`. |
| `organizationFolders` | `[]` | GitHub organization folders: `{name, owner}`. |
| `jenkins` | our overrides | Upstream chart values: controller image, agents, persistence. Plugin pins live in `plugins/plugins.txt`. |
| `jenkins.agentAffinity` | `{}` | Kubernetes affinity for both agent pod templates (generic and deployer). Empty allows any node. |

If you turn on a resource and you do not set a required value, `helm template` stops with an error message.

## 5. Pipeline usage

Jenkins has two pod templates.

| Label | Use | Cluster access |
| --- | --- | --- |
| `generic` | All build and test stages. This is the default, also for `agent any`. | None. The pod has no Kubernetes token. |
| `deployer` | Deploy stages only. | `admin` in the namespaces of `deployNamespaces` only. |

The `deployer` template is EXCLUSIVE. Jenkins uses it only when a stage asks for the label `deployer`.

```groovy
stage('deploy') {
  agent { label 'deployer' }
  steps { container('kubectl') { sh 'kubectl apply -f k8s/' } }
}
```

A library has no default version unless you set `sharedLibraries[].defaultVersion`.
Without `defaultVersion`, a `@Library` line with no version fails.
Pin the version in each `Jenkinsfile`:

```groovy
@Library('<name>@<version>') _
```

## 6. Operator one-time setup

Do these steps one time before the first install.
The Jira sub-tasks of DEVSECOPS-32 give each step click by click.

1. **Keycloak.** Make the `jenkins` client with PKCE, the `groups` mapper and the groups `jenkins-admins` and `jenkins-users`.
2. **GitHub App.** Make the App with the webhook on `https://<webhook-host>/github-webhook/`. Convert the private key to PKCS#8. Install the App on the repositories that Jenkins must build.
3. **Infisical.** Add the keys in `/jenkins/oidc` and `/jenkins/github`. Make the empty folder `/jenkins/admin`. Give the machine identity read rights on `/jenkins/**` and write rights on `/jenkins/admin`.
4. **Repository and package.** In this repository, let GitHub Actions create pull requests. After the first publish, make the GHCR package `charts/jenkins` public.

The deployment and the live checks are in the runbook sub-task (R1 to R4).

## Local controller image test

Build the image from the same files that CI uses:

```bash
docker build -t jenkins-controller:local plugins
bash tests/integration/controller/run.sh jenkins-controller:local
```

The image installs `plugins/plugins.lock.txt`. The lock lists every plugin with an
exact version, so the build resolves nothing. The published chart selects the
finished image by digest, so a deployment does not resolve plugins again.

## Plugin lock

`plugins/plugins.txt` lists only the plugins we choose, each pinned.
`plugins/plugins.lock.txt` is generated from it. Do not edit the lock by hand.

```bash
bash plugins/lock.sh          # resolve plugins.txt and write the lock (needs Docker)
bash plugins/lock.sh --check  # check that the lock keeps every pin (CI runs this)
```

`lock.sh` runs `jenkins-plugin-cli --latest true --no-download` in the Dockerfile
base image. The pins in `plugins.txt` stay as written. Each dependency gets the
newest version that is compatible with that Jenkins core.
The integration test fails if the image does not contain exactly the lock.

## 7. Runbook

- **Escape hatch.** If the escape-hatch password fails, use the previous version in Infisical history, or restart the controller pod.
- **New deploy namespace.** The namespace must exist before you add it to `deployNamespaces`.
- **Revoke deploy rights.** Remove the namespace from `deployNamespaces`. Then run `kubectl -n <ns> delete rolebinding jenkins-deployer`. The Application has prune off, so Argo CD does not delete the old RoleBinding.
- **Plugin upgrade.** To change a plugin we choose, edit its pin in `plugins/plugins.txt`. To update dependencies, change nothing. Then run `bash plugins/lock.sh` and commit `plugins.txt` and `plugins.lock.txt` together. CI builds and tests the image. Deploy the new chart version.
- **Plugin warnings in the UI.** Do not update plugins in the Jenkins UI. The next restart removes those updates. Run `bash plugins/lock.sh` and ship a new image.
- **Hook-range PR.** A merged hook-range PR publishes a new chart version. Bump `targetRevision` in `cluster-config`. If you do not, the new GitHub ranges stay blocked.
- **Infisical change.** The Kubernetes Secret gets the new value within 60 s. Jenkins reads the value only at a JCasC reload or a restart.
- **Controller start.** The image contains the plugins. The init container removes old plugins from the home volume; the controller copies the image's plugin set at startup. No plugins are downloaded at startup. UI-installed plugins do not survive a restart.
- **`HOOKS_TICKET_KEY`.** This optional repository variable sets the Jira key in the hook-range branch name.
- **Note for DEVSECOPS-34.** Change-request builds (`env.CHANGE_ID` is set) must never use the `deployer` label.
