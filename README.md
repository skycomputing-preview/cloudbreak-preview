# cloudbreak-preview

Preview builds of CloudBreak for collaborators. The `preview` workflow
(`.github/workflows/preview.yml`) does three things:

1. Boots the published CloudBreak images two ways: `docker compose` and the
   Helm chart on k3s. The images come from the private
   `ghcr.io/united-clouds/cloudbreak` packages.
2. Smoke-tests each stack (`.github/scripts/tier2-smoke.sh`).
3. Keeps each stack up for a while behind a Cloudflare Tunnel, so
   collaborators can try the UI, then tears it down.

It runs nightly (05:13 UTC) and on demand. No CloudBreak source lives here,
only the deploy files it needs ([Vendored files](#vendored-files)).

## Run a preview

Actions → **preview** → Run workflow:

| Input | Default | |
|---|---|---|
| `tag` | `main` | Which image build: `main` (the newest merge), `sha-<commit>`, `pr-<n>`, a dispatch tag or a release. |
| `target` | `both` | `compose`, `k3s` or `both`. |
| `hold_minutes` | `60` | How long each stack stays up for collaborators after its smoke passes. `0` = smoke only; max `300`. |

- **Ending early:** cancel the run. Teardown still runs.
- **Starting another run:** a new run of a job cancels the one holding that
  job's tunnel, so there is only ever one stack per tunnel. The nightly run
  does the same to a preview that is still up.
- **When the preview is live:** once the smoke passes, the job summary says
  which preview is up.

## Secrets and variables

| Name | Kind | |
|---|---|---|
| `CB_PREVIEW_PKG_PAT` | secret | **Required.** A token with `read:packages` on the private images. Used for `docker login` (compose) and as the k3s image pull secret. |
| `CB_PREVIEW_CF_DC_TT` | secret | Tunnel token for the compose preview. |
| `CB_PREVIEW_CF_DC_URL` | secret | Public base URL of the compose preview, e.g. `https://dc.preview.example.com`. |
| `CB_PREVIEW_CF_K3S_TT` | secret | Tunnel token for the k3s preview. |
| `CB_PREVIEW_CF_K3S_URL` | secret | Public base URL of the k3s preview. |
| `CB_PREVIEW_HOLD_MINUTES` | variable | Optional. Hold time for the nightly run (default 60). |
| `CB_IMAGE_REGISTRY` | variable | Optional. Default `ghcr.io/united-clouds/cloudbreak`. |
| `CB_PREVIEW_PKG_USER` | variable | Optional. Registry username sent with the token (default: this repo's owner; GHCR identifies the caller by the token). |

If a stack's token or URL is missing, that stack still gets smoke-tested but
is not exposed.

## Cloudflare setup

Each tunnel is remotely managed. Set these in the Cloudflare dashboard:

- **Public hostname → service:** `http://localhost:80` for both tunnels.
  `cloudflared` runs on the runner's host network. Compose publishes its
  Traefik gateway on port 80; on k3s, the bundled Traefik's load balancer
  binds port 80.
- **Cloudflare Access application** covering the whole hostname, with a
  policy for your collaborators.

The workflow **fails closed**. After `cloudflared` reports a live connection,
the job requests `/` and `/api/healthz` on the public URL without
credentials. It continues only if Cloudflare Access sends the request to its
login page or refuses it (401/403). If either path answers with anything else,
such as a 2xx (the hostname is open to the internet), the job stops and tears
the stack down.

Collaborators then sign in through Cloudflare Access and pick a persona in the
SPA. The stacks run CloudBreak's dev-session auth (`AUTH_MODE=dev`): any
persona, no password. That is why Access is required.

## This repo is public

Workflow logs and artifacts here are public:

- Secrets are masked in logs, and so is the bare tunnel hostname, which
  `cloudflared` would otherwise print.
- Application logs are collected only when a job fails, and kept for 3 days.
  A successful run uploads none of what collaborators did during the hold.
- Only users with write access can start a run. Pull requests don't trigger
  the workflow, so forks never see the secrets.

## Vendored files

These files are copied byte for byte from the private `united-clouds/cloudbreak`
repo. The commit they came from is in `deploy/SOURCE`.

| Path | |
|---|---|
| `deploy/compose.tier2.yml` | The Tier-2 stack on docker compose, behind a Traefik gateway. |
| `deploy/chart/` | The Helm chart: the same stack behind a Gateway API `HTTPRoute`. |
| `deploy/k3s/traefik-gateway.yaml` | Turns on the Gateway API provider of k3s's bundled Traefik. |
| `.github/scripts/tier2-smoke.sh` | The smoke both jobs run. |

Comments in these files refer to paths in that repo. To refresh them from a
checkout of it:

```bash
scripts/sync-from-cloudbreak.sh ../cloudbreak            # origin/main
scripts/sync-from-cloudbreak.sh ../cloudbreak <ref>      # or a branch, tag or commit
```

The workflow itself is a port of that repo's `.github/workflows/smoke.yml`,
with the tunnel and hold steps added. Its S6 demo-arc step needs the
CloudBreak source, so it stays there.
