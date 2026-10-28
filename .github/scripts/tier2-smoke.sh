#!/usr/bin/env bash
# The Tier-2 smoke, shared by .github/workflows/smoke.yml's compose and k3s
# jobs: every hop answers through the browser's single seam.
#
#   UI_URL    the SPA origin — /api and /events must route to the BFF from here
#             (compose and k3s alike: the Traefik gateway)
#   CORE_URL  real-core, for /readyz (never browser-reachable; the jobs expose it)
#   BFF_URL   the BFF, for /readyz
#
# Leaves core-readyz.json, session.json and shell.html in the working directory.
set -euo pipefail
: "${UI_URL:?}" "${CORE_URL:?}" "${BFF_URL:?}"

# curl for one hop: the body on stdout; on an HTTP error, the URL, status
# and body as an annotation, so the job log says WHICH hop answered what.
fetch() {
  local url=$1 out code
  shift
  out="$(curl -sS -w '\n%{http_code}' "$@" "$url")"
  code="${out##*$'\n'}"
  out="${out%$'\n'*}"
  if [ "$code" -ge 400 ]; then
    out="${out//$'\n'/ }"
    echo "::error::$url answered HTTP $code: ${out:0:400}" >&2
    return 1
  fi
  printf '%s' "$out"
}

echo "::group::real-core /readyz (stub worker on all four family queues)"
fetch "$CORE_URL/readyz" | tee core-readyz.json
echo
for q in cb-migration cb-assessment cb-tco cb-cluster-lifecycle; do
  grep -q "\"queue\":\"$q\"" core-readyz.json || { echo "::error::queue $q missing from readyz"; exit 1; }
done
echo "::endgroup::"
fetch "$BFF_URL/readyz"
echo
# The SPA and a client-side deep link both serve the app shell.
fetch "$UI_URL/" > shell.html
grep -q '<div id="root"' shell.html
fetch "$UI_URL/operations/deep/link" > shell.html
grep -q '<div id="root"' shell.html
# Connect JSON through /api (prefix stripped) → BFF → core, bound to the
# seeded world's user row.
fetch "$UI_URL/api/cb.bff.v1.SessionService/GetSession" -X POST \
  -H 'content-type: application/json' -H 'x-dev-user: sysadmin' -d '{}' | tee session.json
echo
grep -q '"authenticated":true' session.json
grep -q 'system-admin@acme.example' session.json
# SSE through /events, unbuffered: the first frame arrives before the stream
# is cut.
sse="$(timeout 3 curl -sS -N -H 'x-dev-user: sysadmin' "$UI_URL/events" || true)"
[[ "$sse" == ":open"* ]] || { echo "::error::no :open frame through /events (got: ${sse:0:80})"; exit 1; }
echo "smoke: ok"
