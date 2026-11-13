#!/usr/bin/env bash
# Preview-only (the sync leaves it alone). The smoke proves every hop answers;
# this proves the Temporal workflows run. It drives real runs through the
# browser's single seam as the dev personas, walks their gates, then asks
# Temporal itself about each run: the parent (the run's operation name) and
# every phase child the stub worker served (<operation>/<phase>/<attempt>),
# which must have COMPLETED on its family queue.
#
#   UI_URL    the gateway: /api routes to the BFF. Dev sessions (x-dev-user),
#             so this runs before the oidc switch.
#   TEMPORAL  the temporal CLI beside the server, as words: "docker compose
#             ... exec -T temporal temporal" or "kubectl -n <ns> exec
#             deploy/temporal -- temporal"
#
# Six runs, in this order (the rejected S6 needs retail-loyalty still at home
# on aws-eu; the completed S6 then moves it, and the return trip brings it
# back; S1 and S2 depend on none of them):
#   S5         TCO comparison of retail-loyalty → DONE   cb-tco: compare
#   S6         retail-loyalty → azure-eu, provision review
#              rejected → ABORTED, the group unmoved     cb-migration: plan, provision, rollback
#   S6         the same move, every gate approved → DONE cb-migration: plan, provision, cutover
#   S6 return  azure-eu → aws-eu, every gate → DONE      cb-migration: plan, provision, cutover
#   S1         assessment of Checkout → DONE             cb-assessment: assess
#   S2         an HA cluster on azure-eu → DONE          cb-cluster-lifecycle: create
#
# Afterwards, what collaborators find during the hold: retail-loyalty still on
# aws-eu/standard, with one TCO comparison, one aborted and two completed
# migrations (each with its report and settled gate cards); Checkout carrying
# an assessment; azure-eu with a second (HA) cluster. retail-loyalty ends back
# on aws-eu because Arc 3 of the demo arcs (united-clouds/cloudbreak
# integration/e2e/demo-arcs.spec.ts) starts it there. Checkout appears only in
# Arc 1's refusal beats, which depend on it not being on CloudBreak; an
# assessment doesn't change that.
#
# Leaves workflows.md (also added to the step summary) and workflows.log
# (every terminal RunView and Temporal description read) in the working
# directory.
set -euo pipefail
shopt -s inherit_errexit # a failure inside $(...) fails the assignment
: "${UI_URL:?}" "${TEMPORAL:?}"
read -r -a temporal <<<"$TEMPORAL"
stderr="$(mktemp)"
trap 'rm -f "$stderr"' EXIT

GROUP=workloadGroups/retail-loyalty
HOME_SITE=sites/aws-eu
HOME_CLUSTER=sites/aws-eu/clusters/standard
TARGET=sites/azure-eu # same geography and compliance as aws-eu (D4)
TARGET_CLUSTER=sites/azure-eu/clusters/standard
WAIT=${WAIT_SECONDS:-120} # per wait; the stub worker paces 250 ms a step

: >workflows.log
{
  echo "### Temporal workflows"
  echo
  echo "| Scenario | Run | Workflow | Type | Task queue | Status |"
  echo "|---|---|---|---|---|---|"
} >workflows.md

# rpc PERSONA METHOD JSON: Connect JSON through /api, as the persona; the
# response body on stdout. A mutating call carries a fresh Idempotency-Key,
# as the SPA's do. On an HTTP error, the method, status and body as an
# annotation.
rpc() {
  local who=$1 method=$2 body=$3 out code key=()
  case "$method" in
    */Get* | */List*) ;;
    *) key=(-H "idempotency-key: $(cat /proc/sys/kernel/random/uuid)") ;;
  esac
  if ! out="$(curl -sS -w '\n%{http_code}' -X POST "$UI_URL/api/cb.bff.v1.$method" \
    -H 'content-type: application/json' -H "x-dev-user: $who" "${key[@]}" -d "$body")"; then
    echo "::error::$method as $who: no answer from $UI_URL" >&2
    return 1
  fi
  code="${out##*$'\n'}"
  out="${out%$'\n'*}"
  if [ "$code" -ge 400 ]; then
    out="${out//$'\n'/ }"
    echo "::error::$method as $who answered HTTP $code: ${out:0:400}" >&2
    return 1
  fi
  printf '%s' "$out"
}

# start PERSONA METHOD JSON: start a run; its operation name on stdout.
start() {
  local op
  op="$(rpc "$@" | jq -r '.operationId // empty')"
  if [ -z "$op" ]; then
    echo "::error::$2 returned no operation id" >&2
    return 1
  fi
  printf '%s' "$op"
}

# view OP: the run's RunView, read as the supervisor (unscoped: it reads
# every run kind, the site-scoped deploy included).
view() { rpc supervisor ViewService/GetRun "{\"operation\":\"$1\"}"; }

# settle OP PHASE: wait for the run to finish, and fail unless it finished
# in OPERATION_PHASE_<PHASE>.
settle() {
  local op=$1 want=OPERATION_PHASE_$2 v deadline=$((SECONDS + WAIT))
  while :; do
    v="$(view "$op")"
    [ "$(jq -r '.done // false' <<<"$v")" = true ] && break
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "::error::$op is still running after ${WAIT}s: $(jq -c . <<<"$v")"
      return 1
    fi
    sleep 1
  done
  jq -c . <<<"$v" >>workflows.log
  if [ "$(jq -r .phase <<<"$v")" != "$want" ]; then
    echo "::error::$op finished $(jq -r .phase <<<"$v"), not $want: $(jq -c . <<<"$v")"
    return 1
  fi
  echo "  $op: $want"
}

# decide PERSONA OP approve|reject: wait until PERSONA holds a pending card on
# the run (a gate it parked on), then approve or reject it.
decided=()
decide() {
  local who=$1 op=$2 verdict=$3 task deadline=$((SECONDS + WAIT))
  while :; do
    task="$(rpc "$who" TaskService/ListTasks "{\"operation\":\"$op\"}" |
      jq -r --arg decided "${decided[*]:-}" '[.tasks[]?
        | select(.state == "TASK_STATE_PENDING" and .canApprove == true)
        | select(.task as $t | $decided | split(" ") | index($t) | not)][0].task // empty')"
    [ -n "$task" ] && break
    if [ "$(view "$op" | jq -r '.done // false')" = true ]; then
      echo "::error::$op finished before a gate for $who: $(view "$op" | jq -c .)"
      return 1
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "::error::no gate card for $who on $op after ${WAIT}s: $(view "$op" | jq -c .)"
      return 1
    fi
    sleep 1
  done
  decided+=("$task")
  if [ "$verdict" = approve ]; then
    rpc "$who" TaskService/ApproveTask "{\"task\":\"$task\"}" >/dev/null
    echo "  $op: $who approved $task"
  else
    rpc "$who" TaskService/RejectTask \
      "{\"task\":\"$task\",\"reason\":\"preview: exercise the rollback\"}" >/dev/null
    echo "  $op: $who rejected $task"
  fi
}

# placed: the cluster retail-loyalty is placed on (its window, as its owner).
placed() {
  rpc rd-owner ViewService/GetWorkloadGroupWindow "{\"workloadGroup\":\"$GROUP\"}" |
    jq -r '.cluster // empty'
}

# describe ID: Temporal's description of the execution, once it has closed.
# stderr apart: `compose exec` may warn there, and stdout must stay JSON.
describe() {
  local id=$1 out err deadline=$((SECONDS + 30))
  while :; do
    if ! out="$("${temporal[@]}" workflow describe --workflow-id "$id" --output json 2>"$stderr")"; then
      err="$(tr '\n' ' ' <"$stderr")"
      echo "::error::Temporal has no workflow $id: ${err:0:400}" >&2
      return 1
    fi
    [ "$(jq -r .workflowExecutionInfo.status <<<"$out")" != WORKFLOW_EXECUTION_STATUS_RUNNING ] && break
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 1
  done
  jq -c . <<<"$out" >>workflows.log
  printf '%s' "$out"
}

# on_temporal SCENARIO OP [PHASE QUEUE]...: the run's parent workflow closed
# on Temporal, and each named phase child COMPLETED on its family queue.
on_temporal() {
  local scenario=$1 op=$2 d status queue type id
  shift 2
  d="$(describe "$op")"
  status="$(jq -r '.workflowExecutionInfo.status | sub("WORKFLOW_EXECUTION_STATUS_"; "")' <<<"$d")"
  if [ "$status" = RUNNING ]; then
    echo "::error::$op is finished in CloudBreak but its workflow is still running on Temporal"
    return 1
  fi
  echo "| $scenario | \`$op\` | parent | $(jq -r .workflowExecutionInfo.type.name <<<"$d") | $(jq -r '.workflowExecutionInfo.taskQueue // .executionConfig.taskQueue.name' <<<"$d") | $status |" >>workflows.md
  while [ "$#" -gt 0 ]; do
    id="$op/$1/1"
    d="$(describe "$id")"
    status="$(jq -r '.workflowExecutionInfo.status | sub("WORKFLOW_EXECUTION_STATUS_"; "")' <<<"$d")"
    queue="$(jq -r '.workflowExecutionInfo.taskQueue // .executionConfig.taskQueue.name' <<<"$d")"
    type="$(jq -r .workflowExecutionInfo.type.name <<<"$d")"
    echo "| | | \`$id\` | $type | $queue | $status |" >>workflows.md
    if [ "$queue" != "$2" ] || [ "$status" != COMPLETED ]; then
      echo "::error::$id ($type) ran on $queue and ended $status; expected COMPLETED on $2"
      return 1
    fi
    echo "  $id: $type COMPLETED on $queue"
    shift 2
  done
}

# migrate SCENARIO DEST VERDICT: an S6 of the group to the site DEST, gate 1
# and plan review approved; provision review gets VERDICT, and an approval
# runs to cut-over. SCENARIO labels the run in the summary table.
migrate() {
  local op scenario=$1 dest=$2 verdict=$3
  op="$(start rd-owner ActionService/RequestMigration "{\"workloadGroups\":[\"$GROUP\"],\"level\":\"MIGRATION_LEVEL_WORKLOAD_GROUP\",\"targetSite\":\"$dest\",\"reason\":\"preview: exercise the Temporal workflows\"}")"
  decide business-owner "$op" approve # gate 1: migration request
  decide rd-owner "$op" approve       # plan review, after the plan child
  decide rd-owner "$op" "$verdict"    # provision review, after the provision child
  if [ "$verdict" = reject ]; then
    settle "$op" ABORTED
    on_temporal "$scenario" "$op" plan cb-migration provision cb-migration rollback cb-migration
  else
    decide business-owner "$op" approve # cut-over
    settle "$op" DONE
    on_temporal "$scenario" "$op" plan cb-migration provision cb-migration cutover cb-migration
  fi
}

if [ "$(placed)" != "$HOME_CLUSTER" ]; then
  echo "::error::$GROUP is not on $HOME_CLUSTER: not the seeded world"
  exit 1
fi

echo "::group::S5: TCO comparison of $GROUP"
op="$(start rd-owner ActionService/CompareTco "{\"workloadGroup\":\"$GROUP\",\"candidateSites\":[\"sites/gcp-eu\",\"$TARGET\"]}")"
settle "$op" DONE
report="$(view "$op" | jq -r '.report // empty')"
[ -n "$report" ] || { echo "::error::$op finished without a report"; exit 1; }
rpc rd-owner ReportService/GetReport "{\"report\":\"$report\"}" >/dev/null
echo "  $op: $report"
on_temporal S5 "$op" compare cb-tco
echo "::endgroup::"

echo "::group::S6: $GROUP → $TARGET, rejected at provision review"
migrate "S6 rejected" "$TARGET" reject
[ "$(placed)" = "$HOME_CLUSTER" ] || { echo "::error::$GROUP moved after a rejected migration"; exit 1; }
echo "::endgroup::"

echo "::group::S6: $GROUP → $TARGET, every gate approved"
migrate S6 "$TARGET" approve
[ "$(placed)" = "$TARGET_CLUSTER" ] || { echo "::error::$GROUP is not on $TARGET_CLUSTER after its migration"; exit 1; }
echo "::endgroup::"

# Home again: Arc 3 of the demo arcs starts retail-loyalty on aws-eu.
echo "::group::S6 return: $GROUP → $HOME_SITE, every gate approved"
migrate "S6 return" "$HOME_SITE" approve
[ "$(placed)" = "$HOME_CLUSTER" ] || { echo "::error::$GROUP is not back on $HOME_CLUSTER after its return"; exit 1; }
echo "::endgroup::"

echo "::group::S1: assessment of Checkout"
op="$(start rd-owner ActionService/AssessPortability '{"workload":"sites/gcp-eu/workloads/checkout"}')"
settle "$op" DONE
on_temporal S1 "$op" assess cb-assessment
echo "::endgroup::"

echo "::group::S2: an HA cluster on $TARGET"
# The request settles gate 1 for the Infra Owner; go-live is the site's
# System Admin's.
op="$(start infra-owner ActionService/DeployCloudBreakToSite "{\"site\":\"$TARGET\",\"clusterType\":\"clusterTypes/ha\"}")"
decide sysadmin "$op" approve
settle "$op" DONE
on_temporal S2 "$op" create cb-cluster-lifecycle
echo "::endgroup::"

cat workflows.md
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat workflows.md >>"$GITHUB_STEP_SUMMARY"; fi
echo "workflows: ok"
