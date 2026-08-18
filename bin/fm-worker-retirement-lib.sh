#!/usr/bin/env bash
# Shared durable worker-retirement event format and identity helpers.
#
# bin/fm-worker-retirement.sh owns the retirement policy and delegates every
# destructive action to bin/fm-teardown.sh.
# This file owns only the event record shape, endpoint identity binding, and
# atomic notice updates so the hook and teardown cannot drift apart.

fm_retirement_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

fm_retirement_event_path() {
  local state=$1 id=$2
  printf '%s/%s.retirement\n' "$state" "$id"
}

fm_retirement_event_field() {
  local file=$1 key=$2
  grep "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_retirement_meta_identity() {
  local meta=$1 id=$2 key count value backend
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ -n "$id" ] || return 1
  backend=$(fm_backend_of_meta "$meta") || return 1
  {
    printf 'task_id=%s\n' "$id"
    printf 'backend=%s\n' "$backend"
    for key in \
      window endpoint_task_id worktree project spawn_gen \
      terminal orca_worktree_id \
      herdr_session herdr_workspace_id herdr_tab_id herdr_pane_id \
      zellij_session zellij_tab_id zellij_pane_id \
      cmux_workspace_id cmux_surface_id; do
      count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
      case "$key" in
        spawn_gen)
          [ "$count" -le 1 ] || return 1
          ;;
        *)
          [ "$count" -le 1 ] || return 1
          ;;
      esac
      value=$(fm_meta_get "$meta" "$key")
      case "$value" in
        *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
      esac
      printf '%s=%s\n' "$key" "$value"
    done
  } | fm_retirement_hash
}

fm_retirement_event_parse() {
  local file=$1 schema task event kind mode spawn_gen endpoint proof report notice extra
  FM_RETIREMENT_EVENT_TASK=
  FM_RETIREMENT_EVENT_TYPE=
  FM_RETIREMENT_EVENT_KIND=
  FM_RETIREMENT_EVENT_MODE=
  FM_RETIREMENT_EVENT_SPAWN_GEN=
  FM_RETIREMENT_EVENT_ENDPOINT=
  FM_RETIREMENT_EVENT_PROOF=
  FM_RETIREMENT_EVENT_REPORT=
  FM_RETIREMENT_EVENT_NOTICE=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 8< "$file" || return 1
  IFS= read -r schema <&8 || { exec 8<&-; return 1; }
  IFS= read -r task <&8 || { exec 8<&-; return 1; }
  IFS= read -r event <&8 || { exec 8<&-; return 1; }
  IFS= read -r kind <&8 || { exec 8<&-; return 1; }
  IFS= read -r mode <&8 || { exec 8<&-; return 1; }
  IFS= read -r spawn_gen <&8 || { exec 8<&-; return 1; }
  IFS= read -r endpoint <&8 || { exec 8<&-; return 1; }
  IFS= read -r proof <&8 || { exec 8<&-; return 1; }
  IFS= read -r report <&8 || { exec 8<&-; return 1; }
  IFS= read -r notice <&8 || { exec 8<&-; return 1; }
  if IFS= read -r extra <&8; then
    : "$extra"
    exec 8<&-
    return 1
  fi
  exec 8<&-
  case "$schema" in schema=*) schema=${schema#schema=} ;; *) return 1 ;; esac
  case "$task" in task_id=*) task=${task#task_id=} ;; *) return 1 ;; esac
  case "$event" in event=*) event=${event#event=} ;; *) return 1 ;; esac
  case "$kind" in kind=*) kind=${kind#kind=} ;; *) return 1 ;; esac
  case "$mode" in mode=*) mode=${mode#mode=} ;; *) return 1 ;; esac
  case "$spawn_gen" in spawn_gen=*) spawn_gen=${spawn_gen#spawn_gen=} ;; *) return 1 ;; esac
  case "$endpoint" in endpoint=*) endpoint=${endpoint#endpoint=} ;; *) return 1 ;; esac
  case "$proof" in proof=*) proof=${proof#proof=} ;; *) return 1 ;; esac
  case "$report" in report=*) report=${report#report=} ;; *) return 1 ;; esac
  case "$notice" in notice_emitted=*) notice=${notice#notice_emitted=} ;; *) return 1 ;; esac
  [ "$schema" = fm-worker-retirement-v1 ] || return 1
  fm_task_id_path_safe "$task" || return 1
  case "$event" in
    pr-merged|local-merged|scout-complete) ;;
    *) return 1 ;;
  esac
  case "$kind" in ship|scout) ;; *) return 1 ;; esac
  case "$mode" in no-mistakes|direct-PR|local-only|scout) ;; *) return 1 ;; esac
  case "$spawn_gen" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [[ "$endpoint" =~ ^[0-9a-f]{64}$ ]] || return 1
  case "$proof" in
    local-merge|scout-report) ;;
    pr-poll:*) [[ "$proof" =~ ^pr-poll:[0-9a-f]{64}$ ]] || return 1 ;;
    *) return 1 ;;
  esac
  case "$report" in
    '') ;;
    *) [[ "$report" =~ ^[0-9a-f]{64}$ ]] || return 1 ;;
  esac
  case "$notice" in 0|1) ;; *) return 1 ;; esac
  FM_RETIREMENT_EVENT_TASK=$task
  FM_RETIREMENT_EVENT_TYPE=$event
  FM_RETIREMENT_EVENT_KIND=$kind
  FM_RETIREMENT_EVENT_MODE=$mode
  # shellcheck disable=SC2034 # Parsed globals are consumed by hook callers.
  FM_RETIREMENT_EVENT_SPAWN_GEN=$spawn_gen
  FM_RETIREMENT_EVENT_ENDPOINT=$endpoint
  # shellcheck disable=SC2034 # Parsed globals are consumed by hook callers.
  FM_RETIREMENT_EVENT_PROOF=$proof
  # shellcheck disable=SC2034 # Parsed globals are consumed by hook callers.
  FM_RETIREMENT_EVENT_REPORT=$report
  # shellcheck disable=SC2034 # Parsed globals are consumed by hook callers.
  FM_RETIREMENT_EVENT_NOTICE=$notice
}

fm_retirement_event_matches_meta() {
  local file=$1 meta=$2 id=$3 expected current event_kind event_mode meta_kind meta_mode
  fm_retirement_event_parse "$file" || return 1
  [ "$FM_RETIREMENT_EVENT_TASK" = "$id" ] || return 1
  expected=$FM_RETIREMENT_EVENT_ENDPOINT
  current=$(fm_retirement_meta_identity "$meta" "$id") || return 1
  [ "$current" = "$expected" ] || return 1
  event_kind=$FM_RETIREMENT_EVENT_KIND
  event_mode=$FM_RETIREMENT_EVENT_MODE
  meta_kind=$(fm_meta_get "$meta" kind)
  [ -n "$meta_kind" ] || meta_kind=ship
  meta_mode=$(fm_meta_get "$meta" mode)
  if [ "$meta_kind" = scout ] && [ -z "$meta_mode" ]; then
    meta_mode=scout
  fi
  [ -n "$meta_mode" ] || meta_mode=no-mistakes
  [ "$meta_kind" = "$event_kind" ] || return 1
  [ "$meta_mode" = "$event_mode" ] || return 1
  case "$FM_RETIREMENT_EVENT_TYPE:$event_kind:$event_mode" in
    pr-merged:ship:no-mistakes|pr-merged:ship:direct-PR|local-merged:ship:local-only|scout-complete:scout:scout) return 0 ;;
    *) return 1 ;;
  esac
}

fm_retirement_event_set_notice() {
  local file=$1 value=$2 tmp line
  case "$value" in 0|1) ;; *) return 1 ;; esac
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  tmp=$(mktemp "${file%/*}/.retirement.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      notice_emitted=*) printf 'notice_emitted=%s\n' "$value" >> "$tmp" || { rm -f "$tmp"; return 1; } ;;
      *) printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; return 1; } ;;
    esac
  done < "$file"
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f -- "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

fm_retirement_event_report_hash() {
  local report=$1
  [ -f "$report" ] && [ ! -L "$report" ] || return 1
  fm_retirement_hash < "$report"
}

fm_retirement_pipeline_state() {
  local id=$1 state_bin=${FM_WORKER_RETIREMENT_CREW_STATE_BIN:-}
  local line state
  if [ -z "$state_bin" ]; then
    state_bin="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}/bin/fm-crew-state.sh"
  fi
  [ -f "$state_bin" ] && [ ! -L "$state_bin" ] && [ -x "$state_bin" ] || return 2
  line=$(FM_HOME="${FM_HOME:-}" FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-}" \
    "$state_bin" "$id" 2>/dev/null) || return 2
  case "$line" in
    'state: done '*|'state: failed '*) state=${line#state: }; state=${state%% *}; printf '%s\n' "$state"; return 0 ;;
    'state: working '*|'state: parked '*|'state: blocked '*|'state: paused '*|'state: unknown '*)
      state=${line#state: }; state=${state%% *}; printf '%s\n' "$state"; return 1 ;;
    *) return 2 ;;
  esac
}
