#!/usr/bin/env bash
# Expose a smoke-tested stack to collaborators through a Cloudflare Tunnel,
# hold it for a while, then take the tunnel down. Used by both jobs of
# .github/workflows/preview.yml.
#
#   preview-tunnel.sh up             start cloudflared, wait for a live tunnel
#                                    connection, then REFUSE to go on unless
#                                    Cloudflare Access answers in front of the URL
#   preview-tunnel.sh check-access   the Access check alone (`up` runs it)
#   preview-tunnel.sh hold <minutes> keep the stack up, checking it, and that
#                                    Access still guards it, every minute
#   preview-tunnel.sh down           stop cloudflared
#
# The jobs run `up` BEFORE the stack serves the tunnel's origin (port 80 is
# closed, or answers 404), so a hostname without Access is caught while there
# is nothing behind it to expose.
#
# Env:
#   TUNNEL_TOKEN       the tunnel's token (up only). Read by cloudflared from the
#                      environment, so it never appears in a process list.
#   PREVIEW_URL        the public base URL, e.g. https://dc.preview.example.com
#   CLOUDFLARED_IMAGE  the pinned cloudflared image (up only)
#   HEALTH_URL         the stack's local health URL (hold only)
#   PREVIEW_URL        is also needed by hold, which keeps checking Access
#
# The tunnel is remotely managed: its public hostname -> origin route lives in
# the Cloudflare dashboard (README.md), not here.
#
# Logs of a public repo's runs are public. cloudflared prints the hostname it
# serves without the scheme, which GitHub's masking of the secret URL would
# not catch, so the bare hostname is masked too.
set -euo pipefail

NAME=cb-preview-tunnel
METRICS=127.0.0.1:20241

# Tolerate a pasted secret: stray whitespace, a missing scheme, a trailing
# slash. Sets PREVIEW_URL (normalized) and PREVIEW_HOST, and masks the host.
normalize_url() {
  PREVIEW_URL=$(printf '%s' "$PREVIEW_URL" | tr -d '[:space:]')
  [[ "$PREVIEW_URL" == *://* ]] || PREVIEW_URL="https://$PREVIEW_URL"
  PREVIEW_URL=${PREVIEW_URL%/}
  PREVIEW_HOST=${PREVIEW_URL#*://}
  PREVIEW_HOST=${PREVIEW_HOST%%/*}
  PREVIEW_HOST=${PREVIEW_HOST%%:*}
  echo "::add-mask::$PREVIEW_HOST"
}

# Returns 0 when Cloudflare Access answers in front of every path, 1 when the
# hostname answers WITHOUT it (open to the internet), 2 when it could not tell
# (no DNS record, unreachable, an error page).
check_access() {
  local path out code location
  # A tunnel's DNS record exists only once the tunnel has a Public Hostname
  # route in the Cloudflare dashboard; say so instead of "HTTP 000".
  if ! getent hosts "$PREVIEW_HOST" >/dev/null; then
    echo "::error::the preview hostname does not resolve. Give this tunnel a Public Hostname (service http://localhost:80) in the Cloudflare dashboard; that creates its DNS record"
    return 2
  fi
  # FAIL CLOSED: the stack runs dev-session auth (any persona, no password),
  # so the URL must never answer without Cloudflare Access in front. An
  # unauthenticated request must be sent to the Access login (3xx to
  # *.cloudflareaccess.com or /cdn-cgi/access/) or refused (401/403).
  for path in / /api/healthz; do
    # curl still writes the -w line (000) when it fails to connect.
    out=$(curl -sS -o /dev/null --max-time 20 -w '%{http_code} %{redirect_url}' "$PREVIEW_URL$path") || true
    read -r code location <<<"$out"
    case "$code" in
      301 | 302 | 303 | 307 | 308)
        if [[ "$location" != *cloudflareaccess.com* && "$location" != */cdn-cgi/access/* ]]; then
          echo "::error::$path redirects somewhere other than the Cloudflare Access login (HTTP $code); not exposing"
          return 1
        fi
        ;;
      401 | 403) ;;
      2??)
        echo "::error::$path answers HTTP $code WITHOUT Cloudflare Access; put an Access application in front of the whole hostname"
        return 1
        ;;
      *)
        # Before the stack is up an unguarded hostname answers 502/530 (no
        # origin) or 404 (k3s's Traefik with no route yet): no Access either.
        echo "::error::$path answered HTTP $code, not the Cloudflare Access login; check the hostname and its Access application"
        return 2
        ;;
    esac
    echo "Cloudflare Access guards $path (HTTP $code)"
  done
}

case "${1:-}" in
up)
  : "${TUNNEL_TOKEN:?}" "${PREVIEW_URL:?}" "${CLOUDFLARED_IMAGE:?}"
  normalize_url
  # Host network: the dashboard's origin (http://localhost:80) is the runner.
  # Metrics on loopback only (cloudflared's default binds every interface).
  docker run -d --name "$NAME" --network host -e TUNNEL_TOKEN "$CLOUDFLARED_IMAGE" \
    tunnel --no-autoupdate --metrics "$METRICS" run >/dev/null
  for _ in $(seq 60); do
    curl -fsS -o /dev/null "http://$METRICS/ready" 2>/dev/null && break
    sleep 2
  done
  if ! curl -fsS -o /dev/null "http://$METRICS/ready" 2>/dev/null; then
    echo "::error::cloudflared has no live tunnel connection after 2 min (wrong or revoked token?)"
    docker logs --tail 20 "$NAME" 2>&1 || true
    exit 1
  fi
  echo "cloudflared: tunnel connected"

  check_access || exit 1
  ;;

check-access)
  : "${PREVIEW_URL:?}"
  normalize_url
  check_access || exit 1
  ;;

hold)
  minutes=${2:?minutes}
  : "${HEALTH_URL:?}" "${PREVIEW_URL:?}"
  normalize_url
  deadline=$((SECONDS + minutes * 60))
  until=$(date -u -d "+${minutes} min" +%H:%M)
  echo "Preview up until ~${until} UTC. Cancel the run to stop it early."
  fails=0
  n=0
  while ((SECONDS < deadline)); do
    access=0
    report=$(check_access) || access=$?
    ((access == 0)) || echo "$report"
    if ((access == 1)); then
      # Access was taken off the hostname mid-hold: end now, not in 3 minutes.
      echo "::error::the preview hostname answers without Cloudflare Access; ending the preview"
      exit 1
    fi
    if ((access == 0)) &&
      curl -fsS -o /dev/null --max-time 10 "$HEALTH_URL" &&
      curl -fsS -o /dev/null --max-time 5 "http://$METRICS/ready"; then
      fails=0
    else
      fails=$((fails + 1))
      echo "::warning::preview check failed ($fails in a row)"
      if ((fails >= 3)); then
        echo "::error::the stack, the tunnel or the Access check failed 3 times in a row; ending the preview"
        exit 1
      fi
    fi
    if ((n % 10 == 0)); then
      echo "preview up: $(((deadline - SECONDS + 59) / 60)) min left"
    fi
    n=$((n + 1))
    sleep 60
  done
  echo "hold over"
  ;;

down)
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  ;;

*)
  echo "usage: $0 up | check-access | hold <minutes> | down" >&2
  exit 2
  ;;
esac
