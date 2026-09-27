# cloudflared_tunnel

Builds [Cloudflare's `cloudflared`](https://github.com/cloudflare/cloudflared) from source and publishes it to Azure Container Registry as:

```
acrswcvessyinc.azurecr.io/cloudflaredtunnel:v1, v2, v3, ...
```

## How it works

```
cloudflare/cloudflared ──(1. Sync)──> ./cloudflared on main ──(2. Build and push)──> acrswcvessyinc.azurecr.io/cloudflaredtunnel:vN
```

| Workflow | What it does |
|---|---|
| **1 - Sync cloudflared source** ([sync-cloudflared.yml](.github/workflows/sync-cloudflared.yml)) | Copies the cloudflared source at a release (default: latest), tag, branch or commit into [cloudflared/](cloudflared/), records what was copied in `cloudflared-source.json` and pushes the commit to `main`. |
| **2 - Build and push image to ACR** ([build-push-acr.yml](.github/workflows/build-push-acr.yml)) | Builds the image from `cloudflared/` and pushes it as `cloudflaredtunnel:vN` and `cloudflaredtunnel:latest`. `N` is one more than the highest `vN` already in the registry, so the first run is `v1`. |

Both workflows run only when you start them.

### Repository layout

| Path | Purpose |
|---|---|
| `cloudflared/` | Copy of the upstream source, written by workflow 1. Don't edit it by hand, because the next sync overwrites it. |
| `cloudflared-source.json` | The upstream ref, commit and version currently in `cloudflared/`. |
| [Dockerfile](Dockerfile) | Builds the image, with `cloudflared/` as the build context. |
| [.github/workflows/](.github/workflows/) | The two workflows. |

## One-time setup

### 1. Azure login with OIDC

Workflow 2 signs in to Azure with **OIDC** (workload identity federation). GitHub issues a short-lived token for each run, and Entra ID trusts it through a federated credential on the service principal. No client secret is stored anywhere.

The workflow needs the following:

| Item | Where it is |
|---|---|
| Client ID of the service principal | The `AZURE_SPN_ID` repository secret. It holds only the client (application) ID, not a password or JSON. |
| Tenant ID | `AZURE_TENANT_ID` in the workflow's `env` block. |
| **AcrPush** role on `acrswcvessyinc` | Role assignment on the registry. No subscription access is needed. |
| A federated credential that trusts this repository | On the service principal's app registration (see below). |
| GitHub environment `acr-push` | The job runs in this environment. GitHub creates it on the first run if it doesn't exist. |

**Federated credential.** This repository uses GitHub's immutable-ID subject format, so the OIDC subject for the job is:

```
repo:VessyInc@325389898/cloudflared_tunnel@1389783739:environment:acr-push
```

The service principal already has a federated credential, `cloudflared-repo-federation`, that matches `repo:VessyInc@325389898/cloudflared_tunnel@1389783739:environment:*`. It covers the job as long as the job runs in an environment. If the credential ever needs recreating, run this:

```bash
az ad app federated-credential create --id <client ID> --parameters '{
  "name": "cloudflared-tunnel-acr-push",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:VessyInc@325389898/cloudflared_tunnel@1389783739:environment:acr-push",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

**Recommended:** in **Settings → Environments → acr-push**, limit deployment branches to `main`. Then only `main` can push images.

### 2. Put the workflows on `main`

GitHub only shows the **Run workflow** button for workflows on the default branch, so commit and push this repository to `main` first.

### 3. Let workflow 1 push to `main`

Workflow 1 pushes its commit with the built-in `GITHUB_TOKEN`, and the workflow grants itself `contents: write`. If `main` has a branch protection rule or ruleset that requires pull requests, that push is rejected. In that case, either relax the rule for this repository or change the workflow to push with a GitHub App or PAT token that is allowed to bypass it.

## Usage

### Step 1: Sync the cloudflared source

1. Go to **Actions → 1 - Sync cloudflared source → Run workflow**.
2. Set **ref**:
   - leave it **empty** for the latest cloudflared release (recommended)
   - enter a release tag such as `2026.9.3` to pin a version
   - enter `master` or a commit SHA to get unreleased code. The version then looks like `2026.9.3-14-gabc1234`.
3. The run commits `Sync cloudflared <version>` to `main`. If `main` already has that source, it commits nothing.

From the command line:

```bash
gh workflow run "1 - Sync cloudflared source"                  # latest release
gh workflow run "1 - Sync cloudflared source" -f ref=2026.9.3  # specific tag
```

### Step 2: Build and push the image

1. Go to **Actions → 2 - Build and push image to ACR → Run workflow**, on branch `main`.
2. Optional: change **platforms** (default `linux/amd64,linux/arm64`).
3. The run pushes `cloudflaredtunnel:vN` and moves `cloudflaredtunnel:latest` to the same image. The run summary shows the tag, cloudflared version and digest.

```bash
gh workflow run "2 - Build and push image to ACR"
```

### How the version number works

- Before building, the workflow lists the tags in `acrswcvessyinc.azurecr.io/cloudflaredtunnel` and adds 1 to the highest tag of the form `v<number>`. Other tags, such as `latest`, are ignored.
- The number comes from the registry, not from the GitHub run number. As a result:
  - a failed run doesn't use up a number
  - re-running never overwrites an existing tag
  - renaming the workflow doesn't reset the count
- Every run publishes a new version, even if the source hasn't changed since the last run.
- Runs are queued rather than run in parallel, so two runs can't take the same number.
- If you delete the highest `vN` from ACR, the next run reuses that number.

To see which cloudflared version a tag contains, run the image with no arguments. The default command is `version`:

```bash
docker run --rm acrswcvessyinc.azurecr.io/cloudflaredtunnel:v1
# cloudflared version 2026.9.3 (built 2026-09-26-21:16 UTC)
```

The image also carries the labels `com.cloudflare.cloudflared.version`, `com.cloudflare.cloudflared.commit` and `org.opencontainers.image.revision` (the commit of this repository that was built).

### Updating to a new cloudflared release

Run workflow 1 with **ref** empty, then run workflow 2. Cloudflare only supports cloudflared releases for about a year, so repeat this regularly.

## Using the image

The entrypoint is `cloudflared --no-autoupdate`, so any arguments you pass are cloudflared commands. The container runs as the non-root user `65532`.

```bash
az acr login --name acrswcvessyinc

# Run a remotely managed tunnel, using the token from the Cloudflare dashboard
docker run -d --name cloudflared --restart unless-stopped \
  -e TUNNEL_TOKEN="<tunnel token>" \
  acrswcvessyinc.azurecr.io/cloudflaredtunnel:v1 tunnel run
```

In deployments (AKS, Container Apps, ACI and so on), pin a specific `vN` tag rather than `latest`. That way, an upgrade is always a deliberate change.

## Building locally

After at least one sync, run this from the repository root:

```bash
docker buildx build \
  --file Dockerfile \
  --build-arg CLOUDFLARED_VERSION="$(jq -r .version cloudflared-source.json)" \
  --tag cloudflaredtunnel:local \
  --load \
  cloudflared

docker run --rm cloudflaredtunnel:local
```

## Why there is a root Dockerfile

The build is based on cloudflare's own `cloudflared/Dockerfile`, with two changes:

- **Version:** cloudflared's Makefile gets the version from `git describe`. The synced copy has no `.git` folder, so the version is passed in from `cloudflared-source.json`. Without this, the binary would report an empty version.
- **Cross-compiling:** the Go build runs on the runner's own architecture and cross-compiles for each platform. This keeps the arm64 build fast, with no emulation.

Workflow 2 reads the Go builder image and the distroless base image from `cloudflared/Dockerfile` on every build. When Cloudflare changes the Go version or base image, this build picks up the change automatically.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `No cloudflared source in this repo yet` | Run workflow 1 first. |
| Azure login fails with `AADSTS700213: No matching federated identity record found` | The job's OIDC subject doesn't match a federated credential. The job must run in an environment, and the credential must match `repo:VessyInc@325389898/cloudflared_tunnel@1389783739:environment:*`. See [Azure login with OIDC](#1-azure-login-with-oidc). |
| Azure login fails with `AADSTS700016` or `AADSTS90002` | `AZURE_SPN_ID` isn't the client ID of the service principal, or `AZURE_TENANT_ID` in the workflow is wrong. |
| `… did not issue a token` or `Could not list existing tags` | The service principal signed in to Azure, but the registry refused it. Check that it has **AcrPush** on `acrswcvessyinc`. |
| Workflow 1 fails at `git push` | `main` is protected. See [step 3 of the setup](#3-let-workflow-1-push-to-main). |
| `Could not read the builder/base images` or the build fails after a sync | Cloudflare changed its Dockerfile or Makefile. Compare `cloudflared/Dockerfile` with the root `Dockerfile` and update the root one to match. |
