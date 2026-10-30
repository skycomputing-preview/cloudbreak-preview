#!/usr/bin/env bash
# The preview's oidc mode (`auth: oidc`): Zitadel as the issuer on the
# tunnel's auth hostname, provisioned with the world's users, and the BFF
# signing collaborators in through it. Used by both jobs of
# .github/workflows/preview.yml.
#
#   preview-oidc.sh start      start Zitadel (detached; init takes a minute or two)
#   preview-oidc.sh provision  wait for the public issuer, provision the realm, then
#                              the preview fix-ups; exports CB_OIDC_CLIENT_ID and
#                              CB_COOKIE_SEAL_KEY to later steps
#   preview-oidc.sh check      the BFF is in oidc mode, and a persona signs in
#                              through Zitadel end to end
#   preview-oidc.sh logs       Zitadel's log tail (on failure)
#   preview-oidc.sh down       stop Zitadel and drop its data
#
# Env:
#   APP_URL          the app's public base URL (behind Cloudflare Access)
#   AUTH_URL         the auth hostname's public base URL (Zitadel; no Access)
#   USER_PASSWORD    every persona's password (provision only)
#   ADMIN_PASSWORD   optional (provision only): set, a Zitadel console admin
#                    (zitadel-admin@acme.example, ORG_OWNER) gets it
#   REAL_CORE_IMAGE  the pulled real-core image: provision.mjs runs inside it,
#                    beside the world file and the YAML parser it reads it with
#
# Both URLs are normalized like preview-tunnel.sh does, and their hostnames
# are masked: this repo's logs are public.
set -euo pipefail

here=$(cd "$(dirname "$0")/../.." && pwd)
STATE=${RUNNER_TEMP:-/tmp}/zitadel-state
ZITADEL=(docker compose -p cb-zitadel -f "$here/deploy/zitadel.preview.yml")
GATEWAY=http://localhost
LOGIN=rd-owner@acme.example
LOGIN_ROLE="R&D Owner"
PW_VERSION=1.63.0

# normalize VAR: tolerate a pasted secret (whitespace, no scheme, a trailing
# slash) in the variable named VAR, and mask its host (on stdout, where the
# runner reads workflow commands).
normalize() {
  local url host
  if [ -z "${!1:-}" ]; then
    echo "::error::$1 is required"
    exit 1
  fi
  url=$(printf '%s' "${!1}" | tr -d '[:space:]')
  [[ "$url" == *://* ]] || url="https://$url"
  url=${url%/}
  host=${url#*://}
  host=${host%%/*}
  host=${host%%:*}
  echo "::add-mask::$host"
  printf -v "$1" '%s' "$url"
}

compose_env() {
  normalize AUTH_URL
  CB_AUTH_HOST=${AUTH_URL#*://}
  export CB_AUTH_HOST CB_ZITADEL_STATE="$STATE"
  # compose interpolates it even for `logs`/`down`; only `start` uses it.
  export ZITADEL_MASTERKEY=${ZITADEL_MASTERKEY:-unused-outside-start-0000000000}
}

case "${1:-}" in
start)
  compose_env
  # The auth hostname's DNS record comes from its Public Hostname on the
  # tunnel; without one, say so now instead of a 5-minute discovery wait.
  if ! getent hosts "$CB_AUTH_HOST" >/dev/null; then
    echo "::error::the auth hostname does not resolve. Give this stack's tunnel a Public Hostname for it (service http://localhost:8200, no Access application) in the Cloudflare dashboard; that creates its DNS record. Or check the *_AUTH_URL secret for a typo"
    exit 1
  fi
  mkdir -p "$STATE"
  chmod 777 "$STATE" # Zitadel and the provisioner write here as their own users
  masterkey=$(openssl rand -hex 16) # exactly the 32 characters Zitadel takes
  echo "::add-mask::$masterkey"
  ZITADEL_MASTERKEY=$masterkey "${ZITADEL[@]}" up -d
  ;;

provision)
  compose_env
  : "${USER_PASSWORD:?}" "${REAL_CORE_IMAGE:?}"
  normalize APP_URL
  echo "::add-mask::$USER_PASSWORD"
  ADMIN_PASSWORD=${ADMIN_PASSWORD:-}
  if [ -n "$ADMIN_PASSWORD" ]; then
    echo "::add-mask::$ADMIN_PASSWORD"
    if [ "$ADMIN_PASSWORD" = "$USER_PASSWORD" ]; then
      echo "::error::CB_PREVIEW_ADMIN_PASSWORD must differ from CB_PREVIEW_OIDC_PASSWORD"
      exit 1
    fi
  fi
  "${ZITADEL[@]}" up -d --wait --no-recreate zitadel

  # The issuer must answer on its PUBLIC URL, unguarded: the BFF fetches
  # discovery, keys and tokens there, server to server, and no browser
  # session can pass Cloudflare Access for it.
  for _ in $(seq 60); do
    out=$(curl -sS --max-time 10 -o discovery.json -w '%{http_code} %{redirect_url}' \
      "$AUTH_URL/.well-known/openid-configuration") || true
    read -r code location <<<"$out"
    case "$code" in
      200) break ;;
      30?)
        if [[ "$location" == *cloudflareaccess.com* || "$location" == */cdn-cgi/access/* ]]; then
          echo "::error::the auth hostname is behind Cloudflare Access. The BFF reaches Zitadel there server to server, so it must NOT have an Access application (README: Cloudflare setup)"
          exit 1
        fi
        ;;
    esac
    sleep 5
  done
  if [ "${code:-}" != 200 ]; then
    if ! getent hosts "$CB_AUTH_HOST" >/dev/null; then
      echo "::error::the auth hostname does not resolve: it needs a Public Hostname on this stack's tunnel (service http://localhost:8200), which creates its DNS record"
      exit 1
    fi
    echo "::error::Zitadel's discovery did not answer on the auth URL (last: HTTP ${code:-none}). Does the tunnel have a Public Hostname for it with service http://localhost:8200?"
    exit 1
  fi
  issuer=$(jq -r .issuer discovery.json)
  if [ "${issuer%/}" != "$AUTH_URL" ]; then
    echo "::error::Zitadel's issuer is not the auth URL: the BFF would refuse every token"
    exit 1
  fi
  echo "issuer answers on the auth URL"

  # The vendored provisioner, inside the real-core image: it resolves the
  # world file (../../worlds/acme.yaml) and its YAML parser
  # (../../dev-fixtures) from where it sits, /app/deploy/zitadel.
  docker run --rm --network host \
    -e ZITADEL_ISSUER="$AUTH_URL" \
    -v "$here/deploy/zitadel/provision.mjs:/app/deploy/zitadel/provision.mjs:ro" \
    -v "$STATE:/app/deploy/zitadel/.state" \
    --entrypoint node "$REAL_CORE_IMAGE" /app/deploy/zitadel/provision.mjs
  # Zitadel and the provisioner wrote the PAT and the client id as their own
  # users; the fix-ups below run as the runner's.
  sudo chmod -R a+rX "$STATE"
  ZITADEL_ISSUER="$AUTH_URL" STATE_DIR="$STATE" APP_URL="$APP_URL" USER_PASSWORD="$USER_PASSWORD" \
    ADMIN_PASSWORD="$ADMIN_PASSWORD" node "$here/.github/scripts/zitadel-preview.mjs"
  if [ -n "$ADMIN_PASSWORD" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "Zitadel console: the auth URL + \`/ui/console\`, as \`zitadel-admin@acme.example\` (CB_PREVIEW_ADMIN_PASSWORD)" >> "$GITHUB_STEP_SUMMARY"
  fi

  seal=$(openssl rand -base64 32)
  echo "::add-mask::$seal"
  {
    echo "CB_OIDC_CLIENT_ID=$(cat "$STATE/client_id")"
    echo "CB_COOKIE_SEAL_KEY=$seal"
    echo "CB_AUTH_URL=$AUTH_URL"
    echo "CB_APP_URL=$APP_URL"
  } >> "$GITHUB_ENV"
  ;;

check)
  : "${USER_PASSWORD:?}"
  normalize APP_URL
  normalize AUTH_URL
  echo "::add-mask::$USER_PASSWORD"
  for _ in $(seq 60); do
    curl -fsS -o /dev/null "$GATEWAY/api/healthz" && break
    sleep 2
  done

  # A dev-mode BFF answers every anonymous request as DEV_USER; an oidc one
  # has no session without the cookie. Retried: the dev-mode BFF can answer
  # for a few seconds after the switch (a terminating pod, the gateway's
  # endpoint update).
  oidc_mode=false
  for _ in $(seq 15); do
    curl -fsS -X POST -H 'content-type: application/json' -d '{}' \
      "$GATEWAY/api/cb.bff.v1.SessionService/GetSession" > anon-session.json || true
    if [ -s anon-session.json ] && ! jq -e '.authenticated == true' anon-session.json >/dev/null; then
      oidc_mode=true
      break
    fi
    sleep 2
  done
  if [ "$oidc_mode" != true ]; then
    echo "::error::the BFF still authenticates anonymous requests: not in oidc mode"
    exit 1
  fi
  personas=$(curl -sS -o /dev/null -w '%{http_code}' "$GATEWAY/api/dev/personas")
  if [ "$personas" != 404 ]; then
    echo "::error::/dev/personas answers HTTP $personas: the dev persona switcher is live in oidc mode"
    exit 1
  fi
  out=$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "$GATEWAY/login")
  read -r code location <<<"$out"
  callback=$(jq -rn --arg u "$APP_URL/callback" '$u|@uri')
  if [ "$code" != 302 ] || [[ "$location" != "$AUTH_URL/oauth/v2/authorize?"* ]] ||
    [[ "$location" != *"redirect_uri=$callback"* ]]; then
    echo "::error::/login does not send the browser to Zitadel with the app's callback (HTTP $code)"
    exit 1
  fi
  echo "BFF in oidc mode: no anonymous session, /login redirects to Zitadel"

  # The sign-in itself, in the runner's Chrome.
  pw="${RUNNER_TEMP:-/tmp}/playwright"
  npm install --silent --no-save --no-audit --no-fund --prefix "$pw" "playwright-core@$PW_VERSION" >/dev/null
  GATEWAY=$GATEWAY APP_URL=$APP_URL AUTH_URL=$AUTH_URL LOGIN=$LOGIN PASSWORD=$USER_PASSWORD \
    EXPECT_ROLE=$LOGIN_ROLE PW_DIR="$pw" \
    node "$here/.github/scripts/oidc-login-check.mjs"
  ;;

logs)
  compose_env
  "${ZITADEL[@]}" ps -a || true
  "${ZITADEL[@]}" logs --no-color --tail 80 zitadel || true
  ;;

down)
  compose_env
  "${ZITADEL[@]}" down -v --remove-orphans || true
  ;;

*)
  echo "usage: $0 start | provision | check | logs | down" >&2
  exit 2
  ;;
esac
