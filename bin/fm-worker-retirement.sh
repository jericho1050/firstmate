#!/usr/bin/env bash
# Guarded event-driven retirement of ordinary finished workers.
#
# Usage:
#   fm-worker-retirement.sh pr-merged <task-id>
#   fm-worker-retirement.sh local-merged <task-id>
#   fm-worker-retirement.sh scout-complete <task-id>
#   fm-worker-retirement.sh recover
#
# This hook never treats idle, a Stop hook, or free-text done as a landing.
# A PR ship requires the durable validated merged-poll receipt, a local-only
# ship requires the confirmed local merge caller, and a scout requires its
# report plus the unresolved-decision completion gate.
# Persistent secondmates are outside this hook and are never retired here.
# The event record binds task id, spawn incarnation, endpoint identity, task
# kind, and delivery mode, survives interruption, and is retried by recover.
# Every destructive action is delegated to bin/fm-teardown.sh without --force.
# A refusal preserves the event and task, and emits one deduplicated wake while
# the durable event remains unresolved.
#
# The runtime boundary is the first session or watcher reload after this script
# and its call sites land; no existing worker is retroactively pruned.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-worker-retirement-lib.sh
. "$SCRIPT_DIR/fm-worker-retirement-lib.sh"

RETIREMENT_LOCK=""
RETIREMENT_LOCK_HELD=0

cleanup() {
  local rc=$?
  if [ "$RETIREMENT_LOCK_HELD" = 1 ]; then
    fm_lock_release "$RETIREMENT_LOCK" || true
    RETIREMENT_LOCK_HELD=0
  fi
  return "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

valid_id() {
  fm_task_id_creation_valid "${1:-}"
}

meta_value() {
  fm_meta_get "$1" "$2"
}

meta_kind() {
  local value
  value=$(meta_value "$1" kind)
  printf '%s\n' "${value:-ship}"
}

meta_mode() {
  local value kind
  value=$(meta_value "$1" mode)
  kind=$(meta_kind "$1")
  if [ "$kind" = scout ] && [ -z "$value" ]; then
    value=scout
  fi
  printf '%s\n' "${value:-no-mistakes}"
}

require_regular_event_path() {
  local event=$1 id=$2 expected
  expected=$(fm_retirement_event_path "$STATE" "$id")
  [ "$event" = "$expected" ] || return 1
  [ -f "$event" ] && [ ! -L "$event" ]
}

pre_event_refuse() {
  local id=$1 reason=$2
  echo "REFUSED: task $id $reason; preserving everything." >&2
  retirement_pre_event_notice "$id" "$reason" || true
  return 1
}

publish_event() {
  local id=$1 event_type=$2 meta=$3 event_file=$4 kind mode spawn_gen endpoint proof='' report='' report_path tmp
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    pre_event_refuse "$id" "has no durable metadata"
    return 1
  }
  if ! fm_backend_validate_task_endpoint "$meta" "$id"; then
    pre_event_refuse "$id" "has an ambiguous or invalid endpoint identity"
    return 1
  fi
  kind=$(meta_kind "$meta")
  mode=$(meta_mode "$meta")
  case "$event_type:$kind:$mode" in
    pr-merged:ship:no-mistakes|pr-merged:ship:direct-PR) ;;
    local-merged:ship:local-only) ;;
    scout-complete:scout:scout) ;;
    pr-merged:secondmate:*|local-merged:secondmate:*|scout-complete:secondmate:*)
      pre_event_refuse "$id" "is a persistent secondmate excluded from worker retirement"
      return 1
      ;;
    *)
      pre_event_refuse "$id" "event $event_type does not match kind=$kind mode=$mode"
      return 1
      ;;
  esac

  spawn_gen=$(meta_value "$meta" spawn_gen)
  [ -n "$spawn_gen" ] || {
    pre_event_refuse "$id" "has no exact spawn incarnation"
    return 1
  }
  case "$spawn_gen" in ''|*[!A-Za-z0-9._-]*)
    pre_event_refuse "$id" "has an invalid spawn incarnation"
    return 1
    ;;
  esac
  if ! endpoint=$(fm_retirement_meta_identity "$meta" "$id"); then
    pre_event_refuse "$id" "has an ambiguous or invalid endpoint identity"
    return 1
  fi

  if [ "$event_type" = local-merged ] \
    && ! fm_retirement_local_merge_confirmed "$STATE" "$meta" "$id"; then
    pre_event_refuse "$id" "local-only work is not confirmed merged into the default branch"
    return 1
  fi

  case "$event_type" in
    pr-merged)
      receipt="$STATE/$id.pr-poll-retirement"
      if ! fm_pr_poll_retirement_receipt_valid "$STATE" "$id"; then
        pre_event_refuse "$id" "lacks a validated merged PR event"
        return 1
      fi
      if [ "$FM_PR_RETIRE_SPAWN_GEN" != "$spawn_gen" ] \
        || [ "$FM_PR_RETIRE_ENDPOINT" != "$endpoint" ]; then
        pre_event_refuse "$id" "has a merged PR receipt bound to a different worker incarnation"
        return 1
      fi
      proof="pr-poll:$(fm_pr_sha256 "$receipt")" || return 1
      ;;
    local-merged)
      proof=local-merge
      ;;
    scout-complete)
      report_path="$DATA/$id/report.md"
      if [ ! -f "$report_path" ] || [ -L "$report_path" ]; then
        pre_event_refuse "$id" "scout task has no regular report"
        return 1
      fi
      if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
        FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-decision-hold.sh" verify "$id" >/dev/null 2>&1; then
        pre_event_refuse "$id" "scout task has not passed its unresolved-decision completion gate"
        return 1
      fi
      if ! report=$(fm_retirement_event_report_hash "$report_path"); then
        pre_event_refuse "$id" "scout task report could not be validated"
        return 1
      fi
      proof=scout-report
      ;;
  esac

  if [ -e "$event_file" ] || [ -L "$event_file" ]; then
    if ! fm_retirement_event_parse "$event_file" \
      || [ "$FM_RETIREMENT_EVENT_TASK" != "$id" ] \
      || [ "$FM_RETIREMENT_EVENT_TYPE" != "$event_type" ] \
      || [ "$FM_RETIREMENT_EVENT_ENDPOINT" != "$endpoint" ]; then
      pre_event_refuse "$id" "already has a conflicting retirement event"
      return 1
    fi
    return 0
  fi
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  tmp=$(mktemp "$STATE/.retirement.XXXXXX") || return 1
  {
    printf 'schema=fm-worker-retirement-v1\n'
    printf 'task_id=%s\n' "$id"
    printf 'event=%s\n' "$event_type"
    printf 'kind=%s\n' "$kind"
    printf 'mode=%s\n' "$mode"
    printf 'spawn_gen=%s\n' "$spawn_gen"
    printf 'endpoint=%s\n' "$endpoint"
    printf 'proof=%s\n' "$proof"
    printf 'report=%s\n' "$report"
    printf 'notice_emitted=0\n'
    printf 'teardown_handoff=0\n'
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! mv -f -- "$tmp" "$event_file"; then
    rm -f "$tmp"
    return 1
  fi
  fm_retirement_event_parse "$event_file" || return 1
  printf 'recorded retirement event: %s %s\n' "$event_type" "$id"
}

open_decisions() {
  local status_file=$1
  [ -f "$status_file" ] || return 0
  status_open_decisions "$status_file"
}

retirement_pre_event_notice() {
  local id=$1 reason=$2 key payload marker
  key="worker-retirement:$id"
  payload="worker retirement needs attention for $id: $reason"
  marker=$(fm_retirement_notice_marker_path "$STATE" "$id")
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    fm_retirement_notice_marker_valid "$STATE" "$id" "$marker" || return 1
    return 0
  fi
  if fm_wake_queued_keys check 2>/dev/null | grep -Fx -- "$key" >/dev/null 2>&1; then
    fm_retirement_notice_marker_mark "$STATE" "$id"
    return $?
  fi
  fm_wake_append check "$key" "$payload" || return 1
  fm_retirement_notice_marker_mark "$STATE" "$id" || return 1
  printf 'actionable: %s\n' "$payload"
}

retirement_notice() {
  local event_file=$1 id=$2 reason=$3 notice key payload marker
  notice=$(fm_retirement_event_field "$event_file" notice_emitted)
  [ "$notice" = 1 ] && return 0
  marker=$(fm_retirement_notice_marker_path "$STATE" "$id")
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    fm_retirement_notice_marker_valid "$STATE" "$id" "$marker" || return 1
    return 0
  fi
  key="worker-retirement:$id"
  payload="worker retirement needs attention for $id: $reason"
  if fm_wake_queued_keys check 2>/dev/null | grep -Fx -- "$key" >/dev/null 2>&1; then
    fm_retirement_event_set_notice "$event_file" 1 || return 1
    return 0
  fi
  fm_wake_append check "$key" "$payload" || return 1
  fm_retirement_event_set_notice "$event_file" 1 || return 1
  printf 'actionable: %s\n' "$payload"
}

refuse_event() {
  local event_file=$1 id=$2 reason=$3
  if retirement_notice "$event_file" "$id" "$reason"; then
    printf 'REFUSED: worker retirement for %s: %s. Preserving everything; retry after repair.\n' "$id" "$reason" >&2
    return 1
  fi
  printf 'REFUSED: worker retirement for %s: %s. Preserving everything; retry after repair.\n' "$id" "$reason" >&2
  return 1
}

validate_event_proof() {
  local event_file=$1 id=$2 report_path meta
  meta="$STATE/$id.meta"
  case "$FM_RETIREMENT_EVENT_TYPE" in
    pr-merged)
      case "$FM_RETIREMENT_EVENT_PROOF" in pr-poll:*) ;; *) return 1 ;; esac
      ;;
    local-merged)
      [ "$FM_RETIREMENT_EVENT_PROOF" = local-merge ] || return 1
      if [ "$FM_RETIREMENT_EVENT_HANDOFF" = 1 ]; then
        fm_retirement_local_merge_ancestry_confirmed "$STATE" "$meta" "$id"
      else
        fm_retirement_local_merge_confirmed "$STATE" "$meta" "$id"
      fi
      ;;
    scout-complete)
      [ "$FM_RETIREMENT_EVENT_PROOF" = scout-report ] || return 1
      report_path="$DATA/$id/report.md"
      [ -f "$report_path" ] && [ ! -L "$report_path" ] || return 1
      [ "$(fm_retirement_event_report_hash "$report_path")" = "$FM_RETIREMENT_EVENT_REPORT" ] || return 1
      FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
        FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-decision-hold.sh" verify "$id" >/dev/null 2>&1 || return 1
      ;;
    *) return 1 ;;
  esac
}

apply_event() {
  local event_file=$1 id state_line state meta status_file reason state_line_rc
  fm_retirement_event_parse "$event_file" || {
    echo "REFUSED: invalid retirement event $event_file; preserving everything." >&2
    return 1
  }
  id=$FM_RETIREMENT_EVENT_TASK
  meta="$STATE/$id.meta"
  if [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
    rm -f -- "$event_file"
    printf 'already retired: %s\n' "$id"
    return 0
  fi
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    refuse_event "$event_file" "$id" "task metadata is ambiguous"
    return 1
  }
  fm_retirement_event_matches_meta "$event_file" "$meta" "$id" || {
    refuse_event "$event_file" "$id" "task identity or endpoint no longer matches the durable event"
    return 1
  }
  [ "$FM_RETIREMENT_EVENT_KIND" != secondmate ] || {
    refuse_event "$event_file" "$id" "persistent secondmates are excluded"
    return 1
  }
  validate_event_proof "$event_file" "$id" || {
    refuse_event "$event_file" "$id" "landing or report proof is no longer valid"
    return 1
  }
  status_file="$STATE/$id.status"
  if [ -n "$(open_decisions "$status_file")" ]; then
    refuse_event "$event_file" "$id" "open decisions remain"
    return 1
  fi
  if [ "$FM_RETIREMENT_EVENT_HANDOFF" = 0 ]; then
    state_line_rc=0
    state_line=$(fm_retirement_pipeline_state "$id") || state_line_rc=$?
    if [ "$state_line_rc" -ne 0 ]; then
      case "$state_line_rc" in
        1) reason="pipeline custody is active, parked, paused, blocked, or unknown" ;;
        *) reason="pipeline custody could not be verified" ;;
      esac
      refuse_event "$event_file" "$id" "$reason"
      return 1
    fi
    state=$state_line
    case "$state" in done|failed) ;; *) refuse_event "$event_file" "$id" "worker is not in a terminal state"; return 1 ;; esac
  fi

  if FM_WORKER_RETIREMENT_EVENT="$event_file" \
    FM_WORKER_RETIREMENT_CREW_STATE_BIN="${FM_WORKER_RETIREMENT_CREW_STATE_BIN:-}" \
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$SCRIPT_DIR/fm-teardown.sh" "$id" </dev/null; then
    rm -f -- "$event_file" || return 1
    printf 'retired worker: %s\n' "$id"
    return 0
  fi
  refuse_event "$event_file" "$id" "fm-teardown refused or could not complete"
}

lock_event() {
  local id=$1
  RETIREMENT_LOCK="$STATE/.worker-retirement-$id.lock"
  fm_lock_acquire_wait "$RETIREMENT_LOCK"
  RETIREMENT_LOCK_HELD=1
}

handle_one() {
  local event_type=$1 id=$2 meta event_file meta_lock
  valid_id "$id" || { echo "error: invalid task id" >&2; return 2; }
  event_file=$(fm_retirement_event_path "$STATE" "$id")
  lock_event "$id" || return 1
  meta="$STATE/$id.meta"
  if [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
    if [ -e "$event_file" ] || [ -L "$event_file" ]; then
      apply_event "$event_file"
    else
      printf 'ignored: task %s has no metadata or retirement event\n' "$id"
    fi
    return 0
  fi
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    pre_event_refuse "$id" "metadata is ambiguous"
    return 1
  }
  meta_lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$meta_lock" || return 1
  publish_event "$id" "$event_type" "$meta" "$event_file" || {
    fm_lock_release "$meta_lock" || true
    return 1
  }
  fm_lock_release "$meta_lock" || return 1
  apply_event "$event_file"
}

recover_all() {
  local event id rc=0
  for event in "$STATE"/*.retirement; do
    [ -e "$event" ] || [ -L "$event" ] || continue
    if ! fm_retirement_event_parse "$event"; then
      echo "REFUSED: invalid retirement event $event; preserving everything." >&2
      rc=1
      continue
    fi
    id=$FM_RETIREMENT_EVENT_TASK
    if ! valid_id "$id" || ! handle_existing "$event" "$id"; then
      rc=1
    fi
    if [ "$RETIREMENT_LOCK_HELD" = 1 ]; then
      fm_lock_release "$RETIREMENT_LOCK" || rc=1
      RETIREMENT_LOCK_HELD=0
    fi
  done
  return "$rc"
}

recover_local_landed() {
  local receipt id meta kind mode rc=0
  for receipt in "$STATE"/*.local-merge; do
    [ -e "$receipt" ] || [ -L "$receipt" ] || continue
    id=$(basename "$receipt" .local-merge)
    valid_id "$id" || continue
    meta="$STATE/$id.meta"
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    kind=$(meta_kind "$meta")
    mode=$(meta_mode "$meta")
    [ "$kind" = ship ] && [ "$mode" = local-only ] || continue
    if fm_retirement_local_merge_ancestry_confirmed "$STATE" "$meta" "$id" \
      && ! fm_retirement_local_merge_confirmed "$STATE" "$meta" "$id"; then
      pre_event_refuse "$id" "has a local merge receipt bound to a different worker incarnation"
      rc=1
      continue
    fi
    fm_retirement_local_merge_confirmed "$STATE" "$meta" "$id" || continue
    if ! handle_one local-merged "$id"; then
      rc=1
    fi
    if [ "$RETIREMENT_LOCK_HELD" = 1 ]; then
      fm_lock_release "$RETIREMENT_LOCK" || rc=1
      RETIREMENT_LOCK_HELD=0
    fi
  done
  return "$rc"
}

handle_existing() {
  local event_file=$1 id=$2
  valid_id "$id" || return 1
  lock_event "$id" || return 1
  require_regular_event_path "$event_file" "$id" || {
    refuse_event "$event_file" "$id" "retirement event path is ambiguous"
    return 1
  }
  apply_event "$event_file"
}

command=${1:-}
case "$command" in
  pr-merged|local-merged|scout-complete)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    handle_one "$command" "$2"
    ;;
  recover)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    [ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0
    recovery_rc=0
    recover_all || recovery_rc=$?
    recover_local_landed || recovery_rc=$?
    exit "$recovery_rc"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
