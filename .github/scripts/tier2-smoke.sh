#!/usr/bin/env bash
# The Tier-2 smoke, shared by .github/workflows/smoke.yml's compose and k3s
# jobs: every hop answers through the browser's single seam.
#
#   UI_URL    the SPA origin — /api and /events must route to the BFF from here
#             (compose and k3s alike: the Traefik gateway)
#   CORE_URL  real-core, for /readyz and /debug/queues (never browser-reachable;
#             the jobs expose it)
#   BFF_URL   the BFF, for /readyz
#   CB_CORE_SECRET  optional — the core's bearer; when set (the compose job),
#             the census at /debug/queues is read and grepped (W4-H-12)
#
# Leaves core-readyz.json, core-queues.json (with the secret), session.json and
# shell.html in the working directory.
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
# WORKER_EXPECTED=stub with all four queues required: a 200 already means a
# stub poller on each of the four. W4-H-12: the body is the verdict only.
fetch "$CORE_URL/readyz" | tee core-readyz.json
echo
# The census is behind the core's bearer: no header → exactly 401. (`fetch`
# fails on any code ≥ 400, hence the bare curl.)
code="$(curl -s -o /dev/null -w '%{http_code}' "$CORE_URL/debug/queues")"
[ "$code" = 401 ] || { echo "::error::$CORE_URL/debug/queues without the bearer answered $code, not 401"; exit 1; }
if [ -n "${CB_CORE_SECRET:-}" ]; then
  fetch "$CORE_URL/debug/queues" -H "authorization: Bearer $CB_CORE_SECRET" | tee core-queues.json
  echo
  for q in cb-migration cb-assessment cb-tco cb-cluster-lifecycle; do
    grep -q "\"queue\":\"$q\"" core-queues.json || { echo "::error::queue $q missing from /debug/queues"; exit 1; }
  done
else
  echo "no CB_CORE_SECRET here — the census grep is skipped (the 401 check above still ran)"
fi
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
