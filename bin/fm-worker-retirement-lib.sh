#!/usr/bin/env bash
# Shared durable worker-retirement event format and identity helpers.
#
# bin/fm-worker-retirement.sh owns the retirement policy and delegates every
# destructive action to bin/fm-teardown.sh.
# This file owns only the event record shape, endpoint identity binding, and
# atomic notice updates so the hook and teardown cannot drift apart.

fm_retirement_hash() {
  local output hash
  if command -v shasum >/dev/null 2>&1; then
    output=$(shasum -a 256) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    output=$(sha256sum) || return 1
  else
    return 1
  fi
  hash=${output%%[[:space:]]*}
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$hash"
}

fm_retirement_event_path() {
  local state=$1 id=$2
  printf '%s/%s.retirement\n' "$state" "$id"
}

fm_retirement_notice_marker_path() {
  local state=$1 id=$2
  printf '%s/.worker-retirement-notice-%s\n' "$state" "$id"
}

fm_retirement_notice_marker_valid() {
  local state=$1 id=$2 path=$3 value extra
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  path=${path:-$(fm_retirement_notice_marker_path "$state" "$id")}
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  exec 7< "$path" || return 1
  IFS= read -r value <&7 || { exec 7<&-; return 1; }
  if IFS= read -r extra <&7; then
    exec 7<&-
    return 1
  fi
  exec 7<&-
  [ "$value" = fm-worker-retirement-notice-v1 ]
}

fm_retirement_notice_marker_mark() {
  local state=$1 id=$2 path tmp
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  path=$(fm_retirement_notice_marker_path "$state" "$id")
  if [ -e "$path" ] || [ -L "$path" ]; then
    fm_retirement_notice_marker_valid "$state" "$id" "$path"
    return $?
  fi
  tmp=$(mktemp "$state/.worker-retirement-notice.XXXXXX") || return 1
  if ! printf '%s\n' fm-worker-retirement-notice-v1 > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_retirement_notice_marker_valid "$state" "$id" "$path"
}

fm_retirement_notice_ack_key() {
  local state=$1 key=$2 id
  case "$key" in
    worker-retirement:*)
      id=${key#worker-retirement:}
      case "$id" in
        ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
      esac
      if [ -e "$state/$id.meta" ] || [ -L "$state/$id.meta" ] \
        || [ -e "$state/$id.retirement" ] || [ -L "$state/$id.retirement" ]; then
        fm_retirement_notice_marker_mark "$state" "$id"
      fi
      ;;
  esac
}

fm_retirement_local_merge_receipt_path() {
  local state=$1 id=$2
  printf '%s/%s.local-merge\n' "$state" "$id"
}

fm_retirement_local_merge_receipt_parse() {
  local file=$1 schema task branch default branch_tip default_before spawn_gen endpoint extra
  FM_RETIREMENT_LOCAL_MERGE_TASK=
  FM_RETIREMENT_LOCAL_MERGE_BRANCH=
  FM_RETIREMENT_LOCAL_MERGE_DEFAULT=
  FM_RETIREMENT_LOCAL_MERGE_BRANCH_TIP=
  FM_RETIREMENT_LOCAL_MERGE_DEFAULT_BEFORE=
  FM_RETIREMENT_LOCAL_MERGE_SPAWN_GEN=
  FM_RETIREMENT_LOCAL_MERGE_ENDPOINT=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 6< "$file" || return 1
  IFS= read -r schema <&6 || { exec 6<&-; return 1; }
  IFS= read -r task <&6 || { exec 6<&-; return 1; }
  IFS= read -r branch <&6 || { exec 6<&-; return 1; }
  IFS= read -r default <&6 || { exec 6<&-; return 1; }
  IFS= read -r branch_tip <&6 || { exec 6<&-; return 1; }
  IFS= read -r default_before <&6 || { exec 6<&-; return 1; }
  IFS= read -r spawn_gen <&6 || { exec 6<&-; return 1; }
  IFS= read -r endpoint <&6 || { exec 6<&-; return 1; }
  if IFS= read -r extra <&6; then
    exec 6<&-
    return 1
  fi
  exec 6<&-
  case "$schema" in schema=*) schema=${schema#schema=} ;; *) return 1 ;; esac
  case "$task" in task_id=*) task=${task#task_id=} ;; *) return 1 ;; esac
  case "$branch" in branch=*) branch=${branch#branch=} ;; *) return 1 ;; esac
  case "$default" in default=*) default=${default#default=} ;; *) return 1 ;; esac
  case "$branch_tip" in branch_tip=*) branch_tip=${branch_tip#branch_tip=} ;; *) return 1 ;; esac
  case "$default_before" in default_before=*) default_before=${default_before#default_before=} ;; *) return 1 ;; esac
  case "$spawn_gen" in spawn_gen=*) spawn_gen=${spawn_gen#spawn_gen=} ;; *) return 1 ;; esac
  case "$endpoint" in endpoint=*) endpoint=${endpoint#endpoint=} ;; *) return 1 ;; esac
  [ "$schema" = fm-local-merge-v1 ] || return 1
  case "$task" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || return 1
  [[ "$branch_tip" =~ ^[0-9a-f]{40,64}$ ]] || return 1
  [[ "$default_before" =~ ^[0-9a-f]{40,64}$ ]] || return 1
  [ "$branch_tip" != "$default_before" ] || return 1
  case "$spawn_gen" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [[ "$endpoint" =~ ^[0-9a-f]{64}$ ]] || return 1
  git check-ref-format --branch "$default" >/dev/null 2>&1 || return 1
  FM_RETIREMENT_LOCAL_MERGE_TASK=$task
  FM_RETIREMENT_LOCAL_MERGE_BRANCH=$branch
  FM_RETIREMENT_LOCAL_MERGE_DEFAULT=$default
  FM_RETIREMENT_LOCAL_MERGE_BRANCH_TIP=$branch_tip
  FM_RETIREMENT_LOCAL_MERGE_DEFAULT_BEFORE=$default_before
  FM_RETIREMENT_LOCAL_MERGE_SPAWN_GEN=$spawn_gen
  FM_RETIREMENT_LOCAL_MERGE_ENDPOINT=$endpoint
}

fm_retirement_receipt_identity_capture() {
  local state=$1 id=$2 meta count spawn_gen endpoint
  FM_RETIREMENT_RECEIPT_SPAWN_GEN=
  FM_RETIREMENT_RECEIPT_ENDPOINT=
  case "$id" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  meta="$state/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  count=$(grep -c '^spawn_gen=' "$meta" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  spawn_gen=$(fm_meta_get "$meta" spawn_gen)
  case "$spawn_gen" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  endpoint=$(fm_retirement_meta_identity "$meta" "$id") || return 1
  [[ "$endpoint" =~ ^[0-9a-f]{64}$ ]] || return 1
  FM_RETIREMENT_RECEIPT_SPAWN_GEN=$spawn_gen
  FM_RETIREMENT_RECEIPT_ENDPOINT=$endpoint
}

fm_retirement_local_merge_receipt_publish() {
  local state=$1 id=$2 branch=$3 default=$4 branch_tip=$5 default_before=$6
  local path tmp spawn_gen endpoint
  fm_retirement_receipt_identity_capture "$state" "$id" || return 1
  spawn_gen=$FM_RETIREMENT_RECEIPT_SPAWN_GEN
  endpoint=$FM_RETIREMENT_RECEIPT_ENDPOINT
  case "$id" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "$branch" = "fm/$id" ] || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  [[ "$branch_tip" =~ ^[0-9a-f]{40,64}$ ]] || return 1
  [[ "$default_before" =~ ^[0-9a-f]{40,64}$ ]] || return 1
  [ "$branch_tip" != "$default_before" ] || return 1
  path=$(fm_retirement_local_merge_receipt_path "$state" "$id")
  if [ -e "$path" ] || [ -L "$path" ]; then
    fm_retirement_local_merge_receipt_parse "$path" || return 1
    [ "$FM_RETIREMENT_LOCAL_MERGE_TASK" = "$id" ] \
      && [ "$FM_RETIREMENT_LOCAL_MERGE_BRANCH" = "$branch" ] \
      && [ "$FM_RETIREMENT_LOCAL_MERGE_DEFAULT" = "$default" ] \
      && [ "$FM_RETIREMENT_LOCAL_MERGE_BRANCH_TIP" = "$branch_tip" ] \
      && [ "$FM_RETIREMENT_LOCAL_MERGE_DEFAULT_BEFORE" = "$default_before" ] \
      && [ "$FM_RETIREMENT_LOCAL_MERGE_SPAWN_GEN" = "$spawn_gen" ] \
      && [ "$FM_RETIREMENT_LOCAL_MERGE_ENDPOINT" = "$endpoint" ]
    return $?
  fi
  tmp=$(mktemp "$state/.local-merge.XXXXXX") || return 1
  if ! {
    printf 'schema=fm-local-merge-v1\n'
    printf 'task_id=%s\n' "$id"
    printf 'branch=%s\n' "$branch"
    printf 'default=%s\n' "$default"
    printf 'branch_tip=%s\n' "$branch_tip"
    printf 'default_before=%s\n' "$default_before"
    printf 'spawn_gen=%s\n' "$spawn_gen"
    printf 'endpoint=%s\n' "$endpoint"
  } > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_retirement_local_merge_receipt_parse "$path"
}

fm_retirement_local_merge_confirmed() {
  local state=$1 meta=$2 id=$3 project worktree branch default branch_tip current_branch_tip current_identity
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  project=$(fm_meta_get "$meta" project)
  worktree=$(fm_meta_get "$meta" worktree)
  [ -d "$project" ] && [ ! -L "$project" ] || return 1
  [ -d "$worktree" ] && [ ! -L "$worktree" ] || return 1
  fm_retirement_local_merge_receipt_parse "$(fm_retirement_local_merge_receipt_path "$state" "$id")" || return 1
  [ "$FM_RETIREMENT_LOCAL_MERGE_TASK" = "$id" ] || return 1
  branch="fm/$id"
  [ "$FM_RETIREMENT_LOCAL_MERGE_BRANCH" = "$branch" ] || return 1
  default=$FM_RETIREMENT_LOCAL_MERGE_DEFAULT
  branch_tip=$FM_RETIREMENT_LOCAL_MERGE_BRANCH_TIP
  [ "$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = "$branch" ] || return 1
  current_branch_tip=$(git -C "$project" rev-parse --verify --quiet "refs/heads/$branch^{commit}") || return 1
  [ "$current_branch_tip" = "$branch_tip" ] || return 1
  current_identity=$(fm_retirement_meta_identity "$meta" "$id") || return 1
  [ "$current_identity" = "$FM_RETIREMENT_LOCAL_MERGE_ENDPOINT" ] || return 1
  [ "$(fm_meta_get "$meta" spawn_gen)" = "$FM_RETIREMENT_LOCAL_MERGE_SPAWN_GEN" ] || return 1
  fm_retirement_local_merge_ancestry_confirmed "$state" "$meta" "$id"
}

fm_retirement_local_merge_ancestry_confirmed() {
  local state=$1 meta=$2 id=$3 project default branch_tip default_before current_default_tip
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  project=$(fm_meta_get "$meta" project)
  [ -d "$project" ] && [ ! -L "$project" ] || return 1
  fm_retirement_local_merge_receipt_parse "$(fm_retirement_local_merge_receipt_path "$state" "$id")" || return 1
  default=$FM_RETIREMENT_LOCAL_MERGE_DEFAULT
  branch_tip=$FM_RETIREMENT_LOCAL_MERGE_BRANCH_TIP
  default_before=$FM_RETIREMENT_LOCAL_MERGE_DEFAULT_BEFORE
  current_default_tip=$(git -C "$project" rev-parse --verify --quiet "refs/heads/$default^{commit}") || return 1
  git -C "$project" merge-base --is-ancestor "$default_before" "$branch_tip" || return 1
  git -C "$project" merge-base --is-ancestor "$branch_tip" "$current_default_tip"
}

fm_retirement_event_field() {
  local file=$1 key=$2
  grep "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_retirement_meta_identity() {
  local meta=$1 id=$2 key count value backend tmp identity
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ -n "$id" ] || return 1
  backend=$(fm_backend_of_meta "$meta") || return 1
  tmp=$(mktemp "${meta%/*}/.retirement-identity.XXXXXX") || return 1
  : > "$tmp" || { rm -f -- "$tmp"; return 1; }
  printf 'task_id=%s\n' "$id" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  printf 'backend=%s\n' "$backend" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  for key in \
    window endpoint_task_id worktree project spawn_gen \
    terminal orca_worktree_id \
    herdr_session herdr_workspace_id herdr_tab_id herdr_pane_id \
    zellij_session zellij_tab_id zellij_pane_id \
    cmux_workspace_id cmux_surface_id; do
    count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
    if [ "$count" -gt 1 ]; then
      rm -f -- "$tmp"
      return 1
    fi
    value=$(fm_meta_get "$meta" "$key")
    case "$value" in
      *$'\n'*|*$'\r'*|*$'\t'*)
        rm -f -- "$tmp"
        return 1
        ;;
    esac
    printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  done
  identity=$(fm_retirement_hash < "$tmp") || { rm -f -- "$tmp"; return 1; }
  rm -f -- "$tmp" || return 1
  [[ "$identity" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$identity"
}

fm_retirement_event_parse() {
  local file=$1 schema task event kind mode spawn_gen endpoint proof report notice handoff extra
  FM_RETIREMENT_EVENT_TASK=
  FM_RETIREMENT_EVENT_TYPE=
  FM_RETIREMENT_EVENT_KIND=
  FM_RETIREMENT_EVENT_MODE=
  FM_RETIREMENT_EVENT_SPAWN_GEN=
  FM_RETIREMENT_EVENT_ENDPOINT=
  FM_RETIREMENT_EVENT_PROOF=
  FM_RETIREMENT_EVENT_REPORT=
  FM_RETIREMENT_EVENT_NOTICE=
  FM_RETIREMENT_EVENT_HANDOFF=
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
  if IFS= read -r handoff <&8; then
    :
  else
    handoff=teardown_handoff=0
  fi
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
  case "$handoff" in teardown_handoff=*) handoff=${handoff#teardown_handoff=} ;; *) return 1 ;; esac
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
  case "$handoff" in 0|1) ;; *) return 1 ;; esac
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
  FM_RETIREMENT_EVENT_HANDOFF=$handoff
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

fm_retirement_event_set_field() {
  local file=$1 key=$2 value=$3 tmp line found=0
  case "$key:$value" in
    notice_emitted:0|notice_emitted:1|teardown_handoff:0|teardown_handoff:1) ;;
    *) return 1 ;;
  esac
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  tmp=$(mktemp "${file%/*}/.retirement.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key"=*) printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f "$tmp"; return 1; }; found=1 ;;
      *) printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; return 1; } ;;
    esac
  done < "$file"
  [ "$found" = 1 ] || printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f -- "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

fm_retirement_event_set_notice() {
  fm_retirement_event_set_field "$1" notice_emitted "$2"
}

fm_retirement_event_set_handoff() {
  fm_retirement_event_set_field "$1" teardown_handoff "$2"
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
