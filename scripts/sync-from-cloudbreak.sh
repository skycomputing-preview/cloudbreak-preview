#!/usr/bin/env bash
# Refresh the vendored deploy files from a checkout of the private
# united-clouds/cloudbreak repo, and record the commit they came from in
# deploy/SOURCE.
#
#   scripts/sync-from-cloudbreak.sh <path-to-cloudbreak-checkout> [ref]   # ref: origin/main
#
# Copies the files byte for byte (their comments point at paths in that repo).
# Review the diff, then commit it together with any workflow change it needs.
set -euo pipefail

src=${1:?path to a united-clouds/cloudbreak checkout}
ref=${2:-origin/main}
here=$(cd "$(dirname "$0")/.." && pwd)

paths=(
  deploy/compose.tier2.yml
  deploy/k3s/traefik-gateway.yaml
  deploy/chart/Chart.yaml
  deploy/chart/values.yaml
  deploy/chart/templates
  .github/scripts/tier2-smoke.sh
  deploy/zitadel/provision.mjs
)

git -C "$src" fetch --quiet origin
sha=$(git -C "$src" rev-parse "$ref")
rm -rf "$here/deploy/chart/templates"
git -C "$src" archive "$sha" "${paths[@]}" | tar -x -C "$here"
echo "united-clouds/cloudbreak@$sha" > "$here/deploy/SOURCE"
echo "synced from united-clouds/cloudbreak@$sha"
git -C "$here" status --short
