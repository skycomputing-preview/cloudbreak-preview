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
| `auth` | `dev` | How collaborators sign in: `dev` (pick a persona) or `oidc` (a real Zitadel login). See [Signing in](#signing-in). |

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
| `CB_PREVIEW_CF_DC_AUTH_URL` | secret | `auth: oidc` only. Public base URL of the compose stack's Zitadel, e.g. `https://auth-dc.preview.example.com`. |
| `CB_PREVIEW_CF_K3S_AUTH_URL` | secret | `auth: oidc` only. Public base URL of the k3s stack's Zitadel. |
| `CB_PREVIEW_OIDC_PASSWORD` | secret | `auth: oidc` only. The password every persona gets. Share it with collaborators. Zitadel's default policy applies: at least 8 characters, with upper and lower case, a digit and a symbol. |
| `CB_PREVIEW_HOLD_MINUTES` | variable | Optional. Hold time for the nightly run (default 60). |
| `CB_PREVIEW_AUTH` | variable | Optional. Sign-in mode for the nightly run: `dev` (default) or `oidc`. |
| `CB_IMAGE_REGISTRY` | variable | Optional. Default `ghcr.io/united-clouds/cloudbreak`. |
| `CB_PREVIEW_PKG_USER` | variable | Optional. Registry username sent with the token (default: this repo's owner; GHCR identifies the caller by the token). |

If a stack's token or URL is missing, that stack still gets smoke-tested but
is not exposed. `auth: oidc` refuses to start without the secrets it needs,
and names them.

## Cloudflare setup

Each tunnel is remotely managed. Set these in the Cloudflare dashboard:

- **Public hostname → service:** `http://localhost:80` for both tunnels.
  `cloudflared` runs on the runner's host network. Compose publishes its
  Traefik gateway on port 80; on k3s, the bundled Traefik's load balancer
  binds port 80.
- **Cloudflare Access application** covering the whole hostname, with a
  policy for your collaborators.
- **For `auth: oidc`, a second public hostname on each tunnel** (the
  `*_AUTH_URL` secrets) → service `http://localhost:8200`, where the job runs
  Zitadel. **Do not put an Access application on it.** The BFF fetches
  Zitadel's discovery, keys and tokens there server to server, and no
  browser session can pass Access for it. The job stops if Access answers
  there.

The tunnel is the only way in:

- **Compose** publishes every port on loopback only
  (`deploy/compose.preview.yml`), and the job checks Docker's bindings.
- **k3s:** the job drops new inbound connections on the runner's network
  interface to Traefik's ports: 80, 443 and the NodePort range 30000–32767.

Nothing reaches the stack without passing Cloudflare Access.

The workflow **fails closed**:

- **Before the stack starts.** The job starts `cloudflared` before anything
  serves port 80, waits for a live connection, then requests `/` and
  `/api/healthz` on the public URL without credentials. It continues only if
  Cloudflare Access sends the request to its login page or refuses it
  (401/403). Anything else stops the job before the stack is reachable: a
  missing DNS record, an error page or a 2xx.
- **During the hold.** The job repeats that check every minute. If the
  hostname ever answers without Access, the preview ends at once and the
  stack is torn down.

## Signing in

Collaborators always pass Cloudflare Access first. What comes next depends
on `auth`:

- **`dev` (default).** The stack runs CloudBreak's dev sessions
  (`AUTH_MODE=dev`): any persona, no password. That is why Access is
  required. Pick a persona from the menu on the role chip, top right
  (united-clouds/cloudbreak#160). On images older than that, the chip is a
  plain label; switch in the browser console instead with
  `localStorage.setItem('cb_dev_user', 'supervisor'); location.reload()`.
  The keys are `rd-owner`, `rd-owner-2`, `business-owner`,
  `business-owner-2`, `supervisor`, `sysadmin`, `infra-owner`,
  `procurement`, `appowner` and `appowner-2`.
- **`oidc`.** After the smoke, the job starts the BFF's OIDC token-handler
  against a Zitadel provisioned with the world's users
  (`deploy/zitadel/provision.mjs`). It then signs `rd-owner@acme.example`
  in end to end in a headless browser before the hold starts. Collaborators
  click **Sign in** and log in at the auth URL as a persona, with the
  password from `CB_PREVIEW_OIDC_PASSWORD`. Zitadel offers a 2FA setup on
  each user's first login; skip it.

  | Login | Role |
  |---|---|
  | `rd-owner@acme.example`, `rd-owner-2@acme.example` | R&D Owner |
  | `business-owner@acme.example`, `business-owner-2@acme.example` | Business Owner |
  | `supervisor@acme.example` | CloudBreak Supervisor |
  | `system-admin@acme.example` | System Admin |
  | `infra-owner@acme.example` | Infra Owner |
  | `procurement-owner@acme.example` | Procurement Owner |
  | `app-owner@acme.example`, `app-owner-2@acme.example` | Application Owner |

  The auth hostname is public, while the app hostname stays behind Access.
  A Zitadel login alone does not reach the app: the callback and every API
  call go through the app hostname. Zitadel runs only for the hold, with a
  masterkey minted per run; its admin is the provisioner's machine user,
  whose token never leaves the runner.

## This repo is public

Workflow logs and artifacts here are public:

- Secrets are masked in logs, and so are the bare tunnel and auth
  hostnames, which `cloudflared` would otherwise print.
- Application logs are collected only when a job fails, and kept for 3 days.
  A successful run uploads none of what collaborators did during the hold.
- Only users with write access can start a run. Pull requests don't trigger
  the workflow, so forks never see the secrets.

## Vendored files

These files are copied byte for byte from the private `united-clouds/cloudbreak`
repo. Preview-only changes go in separate files, which the sync leaves
alone: `deploy/compose.preview.yml`, `deploy/compose.preview.oidc.yml`,
`deploy/zitadel.preview.yml` and `.github/scripts/zitadel-preview.mjs`
(the preview's redirect URI and persona password, applied after
`provision.mjs`). The commit they came from is in `deploy/SOURCE`.

| Path | |
|---|---|
| `deploy/compose.tier2.yml` | The Tier-2 stack on docker compose, behind a Traefik gateway. |
| `deploy/chart/` | The Helm chart: the same stack behind a Gateway API `HTTPRoute`. |
| `deploy/k3s/traefik-gateway.yaml` | Turns on the Gateway API provider of k3s's bundled Traefik. |
| `.github/scripts/tier2-smoke.sh` | The smoke both jobs run. |
| `deploy/zitadel/provision.mjs` | `auth: oidc`: provisions Zitadel (project, roles, the BFF's app, the world's users). The job runs it inside the real-core image, next to the world file. |

Comments in these files refer to paths in that repo. To refresh them from a
checkout of it:

```bash
scripts/sync-from-cloudbreak.sh ../cloudbreak            # origin/main
scripts/sync-from-cloudbreak.sh ../cloudbreak <ref>      # or a branch, tag or commit
```

The workflow itself is a port of that repo's `.github/workflows/smoke.yml`,
with the tunnel and hold steps added. Its S6 demo-arc step needs the
CloudBreak source, so it stays there.
