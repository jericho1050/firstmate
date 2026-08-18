#!/usr/bin/env bash
# Behavioral coverage for guarded event-driven ordinary-worker retirement.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

HOOK="$ROOT/bin/fm-worker-retirement.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-worker-retirement-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-retirement)

make_case() { # <name> <id>
  local name=$1 id=$2
  CASE="$TMP_ROOT/$name"
  mkdir -p "$CASE/home/state" "$CASE/home/data" "$CASE/home/config" "$CASE/fakebin"
  fm_git_worktree "$CASE/project" "$CASE/wt" "fm/$id"
  cat > "$CASE/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TMUX_LOG:?}"
exit 0
SH
  cat > "$CASE/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_HERDR_LOG:?}"
case "$*" in
  'session list --json --session lab')
    printf '%s\n' '{"sessions":[{"name":"lab","running":true,"socket_path":"/tmp/fm-worker-retirement-herdr.sock"}]}'
    ;;
  'workspace list --session lab')
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","focused":true,"active_tab_id":"w1:t1"}]}}'
    ;;
  'tab list --workspace w1 --session lab')
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}'
    ;;
  'pane get w1:p1 --session lab')
    if [ -e "${FM_HERDR_GONE:?}" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}}}'
    fi
    ;;
  'pane close w1:p1 --session lab')
    : > "${FM_HERDR_GONE:?}"
    printf '%s\n' '{"result":{}}'
    ;;
  *)
    printf '%s\n' '{"error":{"code":"unsupported_test_call"}}'
    exit 1
    ;;
esac
exit 0
SH
  cat > "$CASE/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TREEHOUSE_LOG:?}"
if [ -n "${FM_TREEHOUSE_FAIL_ONCE:-}" ] && [ ! -e "$FM_TREEHOUSE_FAIL_ONCE" ]; then
  : > "$FM_TREEHOUSE_FAIL_ONCE"
  exit 1
fi
exit 0
SH
  cat > "$CASE/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
# No active validation run in ordinary fixtures.
exit 0
SH
  cat > "$CASE/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: test\n' "$(cat "${FM_FAKE_STATE_FILE:?}")"
SH
  chmod +x "$CASE/fakebin"/*
  : > "$CASE/tmux.log"
  : > "$CASE/herdr.log"
  : > "$CASE/herdr-gone"
  : > "$CASE/treehouse.log"
  rm -f "$CASE/herdr-gone"
  printf 'done\n' > "$CASE/crew-state"
}

write_ship_meta() { # <id> <mode>
  local id=$1 mode=$2
  fm_write_meta "$CASE/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$CASE/wt" "project=$CASE/project" \
    'kind=ship' "mode=$mode" 'spawn_gen=one'
  printf 'done: finished\n' > "$CASE/home/state/$id.status"
}

write_scout_meta() { # <id> [<backend>]
  local id=$1 backend=${2:-tmux} window
  window="firstmate:fm-$id"
  if [ "$backend" = herdr ]; then
    window=lab:w1:p1
  fi
  fm_write_meta "$CASE/home/state/$id.meta" \
    "window=$window" "endpoint_task_id=$id" \
    "worktree=$CASE/wt" "project=$CASE/project" "backend=$backend" \
    'kind=scout' 'spawn_gen=one' 'decisions_reviewed=1'
  if [ "$backend" = herdr ]; then
    printf '%s\n' 'herdr_session=lab' 'herdr_workspace_id=w1' \
      'herdr_tab_id=w1:t1' 'herdr_pane_id=w1:p1' \
      >> "$CASE/home/state/$id.meta"
  fi
  printf 'done: report ready\n' > "$CASE/home/state/$id.status"
}

run_hook() { # <event> [<id>]
  local event=$1 id=${2:-} rc=0
  if [ "$event" = recover ]; then
    PATH="$CASE/fakebin:$PATH" \
      FM_HOME="$CASE/home" FM_STATE_OVERRIDE="$CASE/home/state" \
      FM_DATA_OVERRIDE="$CASE/home/data" FM_CONFIG_OVERRIDE="$CASE/home/config" \
      FM_ROOT_OVERRIDE="$ROOT" FM_TMUX_LOG="$CASE/tmux.log" FM_HERDR_LOG="$CASE/herdr.log" \
      FM_HERDR_GONE="$CASE/herdr-gone" FM_TREEHOUSE_LOG="$CASE/treehouse.log" FM_FAKE_STATE_FILE="$CASE/crew-state" \
      FM_WORKER_RETIREMENT_CREW_STATE_BIN="$CASE/fakebin/fm-crew-state.sh" \
      "$HOOK" recover > "$CASE/hook.out" 2> "$CASE/hook.err" || rc=$?
  else
    PATH="$CASE/fakebin:$PATH" \
      FM_HOME="$CASE/home" FM_STATE_OVERRIDE="$CASE/home/state" \
      FM_DATA_OVERRIDE="$CASE/home/data" FM_CONFIG_OVERRIDE="$CASE/home/config" \
      FM_ROOT_OVERRIDE="$ROOT" FM_TMUX_LOG="$CASE/tmux.log" FM_HERDR_LOG="$CASE/herdr.log" \
      FM_HERDR_GONE="$CASE/herdr-gone" FM_TREEHOUSE_LOG="$CASE/treehouse.log" FM_FAKE_STATE_FILE="$CASE/crew-state" \
      FM_WORKER_RETIREMENT_CREW_STATE_BIN="$CASE/fakebin/fm-crew-state.sh" \
      "$HOOK" "$event" "$id" > "$CASE/hook.out" 2> "$CASE/hook.err" || rc=$?
  fi
  return "$rc"
}

arm_local_merge_receipt() { # <id>
  local id=$1 default before branch_tip
  default=$(git -C "$CASE/project" symbolic-ref --quiet --short HEAD) || fail "local fixture has no default branch"
  before=$(git -C "$CASE/project" rev-parse "$default") || fail "local fixture has no default commit"
  branch_tip=$(git -C "$CASE/project" rev-parse "fm/$id") || fail "local fixture has no task commit"
  fm_retirement_local_merge_receipt_publish "$CASE/home/state" "$id" "fm/$id" \
    "$default" "$branch_tip" "$before" || fail "local fixture could not publish merge receipt"
}

land_task() { # <id>
  local id=$1
  printf 'change\n' > "$CASE/wt/change"
  git -C "$CASE/wt" add change
  git -C "$CASE/wt" commit -qm change
  arm_local_merge_receipt "$id"
  git -C "$CASE/project" merge --ff-only "fm/$id" >/dev/null
}

commit_unlanded_task() {
  printf 'change\n' > "$CASE/wt/change"
  git -C "$CASE/wt" add change
  git -C "$CASE/wt" commit -qm change
}

assert_one_retirement_wake() {
  [ "$(grep -c 'worker-retirement:' "$CASE/home/state/.wake-queue" 2>/dev/null || true)" = 1 ] \
    || fail "retirement refusal did not emit exactly one actionable wake"
}

ack_retirement_wake() {
  local output sequence generation
  output=$(FM_HOME="$CASE/home" FM_STATE_OVERRIDE="$CASE/home/state" \
    FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-wake-drain.sh" 2>&1) || fail "retirement wake could not be drained"
  sequence=$(printf '%s\n' "$output" | sed -n 's/.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' | tail -1)
  generation=$(printf '%s\n' "$output" | sed -n 's/.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\).*/\1/p' | tail -1)
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "retirement wake drain omitted acknowledgement"
  FM_HOME="$CASE/home" FM_STATE_OVERRIDE="$CASE/home/state" \
    FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" \
    --recovery-generation "$generation" >/dev/null 2>&1 \
    || fail "retirement wake could not be acknowledged"
}

test_done_before_merge_preserves() {
  make_case done-before-merge done1
  write_ship_meta done1 local-only
  run_hook recover || fail "empty recovery changed done-before-merge case"
  [ -e "$CASE/home/state/done1.meta" ] || fail "done-before-merge removed metadata"
  [ ! -e "$CASE/home/state/done1.retirement" ] || fail "free-text done created retirement authority"
  [ ! -s "$CASE/treehouse.log" ] || fail "free-text done reached destructive cleanup"
  pass "done-before-merge preserves endpoint and worktree"
}

test_merged_clean_success() {
  make_case merged-clean merged1
  write_ship_meta merged1 local-only
  land_task merged1
  run_hook local-merged merged1 || fail "confirmed local merge did not retire worker: $(cat "$CASE/hook.err")"
  [ ! -e "$CASE/home/state/merged1.meta" ] || fail "merged worker metadata survived cleanup"
  [ ! -e "$CASE/home/state/merged1.retirement" ] || fail "completed retirement event survived cleanup"
  [ "$(wc -l < "$CASE/treehouse.log" | tr -d ' ')" = 1 ] || fail "merged worker was not pruned exactly once"
  pass "confirmed clean landing retires worker"
}

test_local_landing_recovery() {
  make_case local-recovery localrecover1
  write_ship_meta localrecover1 local-only
  land_task localrecover1
  run_hook recover || fail "local landing recovery did not retire worker"
  [ ! -e "$CASE/home/state/localrecover1.meta" ] || fail "recovered local landing left metadata"
  [ "$(wc -l < "$CASE/treehouse.log" | tr -d ' ')" = 1 ] || fail "recovered local landing did not prune once"
  pass "local landing recovery re-derives interrupted merge"
}

test_validated_pr_merge_success() {
  local id=prmerge1 url=https://github.com/example/repo/pull/7 provider host path number
  make_case validated-pr-merge "$id"
  write_ship_meta "$id" no-mistakes
  printf 'pr=%s\n' "$url" >> "$CASE/home/state/$id.meta"
  git -C "$CASE/wt" push -q origin "fm/$id"
  git -C "$CASE/project" fetch -q origin
  fm_pr_url_parse "$url" || fail "PR fixture URL did not parse"
  provider=$FM_PR_PROVIDER; host=$FM_PR_HOST; path=$FM_PR_PATH; number=$FM_PR_NUMBER
  fm_pr_poll_prepare "$CASE/home/state" "$id" "$provider" "$url" "$host" "$path" "$number" "$ROOT/bin/fm-pr-poll.sh" \
    || fail "PR fixture poll did not prepare"
  fm_pr_poll_publish_prepared || fail "PR fixture poll did not publish"
  fm_pr_poll_snapshot_capture "$CASE/home/state" "$id" "$ROOT/bin/fm-pr-poll.sh" \
    || fail "PR fixture poll snapshot did not capture"
  fm_pr_poll_retirement_publish "$CASE/home/state" "$id" "$ROOT/bin/fm-pr-poll.sh" merged \
    || fail "PR fixture merged event did not publish"
  run_hook pr-merged "$id" || fail "validated PR merge did not retire worker: $(cat "$CASE/hook.err")"
  [ ! -e "$CASE/home/state/$id.meta" ] || fail "validated PR merge left metadata"
  [ ! -e "$CASE/home/state/$id.pr-poll-retirement" ] || fail "validated PR merge left its proof receipt"
  pass "durable validated PR merge retires worker"
}

test_pr_refusal_preserves_receipt() {
  local id=prrefuse1 url=https://github.com/example/repo/pull/8 provider host path number
  make_case validated-pr-refusal "$id"
  write_ship_meta "$id" no-mistakes
  printf 'pr=%s\n' "$url" >> "$CASE/home/state/$id.meta"
  git -C "$CASE/wt" push -q origin "fm/$id"
  git -C "$CASE/project" fetch -q origin
  fm_pr_url_parse "$url" || fail "PR refusal fixture URL did not parse"
  provider=$FM_PR_PROVIDER; host=$FM_PR_HOST; path=$FM_PR_PATH; number=$FM_PR_NUMBER
  fm_pr_poll_prepare "$CASE/home/state" "$id" "$provider" "$url" "$host" "$path" "$number" "$ROOT/bin/fm-pr-poll.sh" \
    || fail "PR refusal fixture poll did not prepare"
  fm_pr_poll_publish_prepared || fail "PR refusal fixture poll did not publish"
  fm_pr_poll_snapshot_capture "$CASE/home/state" "$id" "$ROOT/bin/fm-pr-poll.sh" \
    || fail "PR refusal fixture poll snapshot did not capture"
  fm_pr_poll_retirement_publish "$CASE/home/state" "$id" "$ROOT/bin/fm-pr-poll.sh" merged \
    || fail "PR refusal fixture merged event did not publish"
  sed -i.bak 's#^window=.*#window=ambiguous#' "$CASE/home/state/$id.meta"
  run_hook pr-merged "$id" && fail "ambiguous endpoint unexpectedly authorized retirement"
  [ -e "$CASE/home/state/$id.pr-poll-retirement" ] || fail "endpoint refusal removed validated receipt"
  [ ! -e "$CASE/home/state/$id.retirement" ] || fail "endpoint refusal created an unbound event"
  [ ! -s "$CASE/treehouse.log" ] || fail "endpoint refusal reached treehouse cleanup"
  assert_one_retirement_wake
  ack_retirement_wake
  [ -e "$CASE/home/state/.worker-retirement-notice-$id" ] \
    || fail "acknowledged refusal did not leave a durable notice marker"
  run_hook pr-merged "$id" && fail "repeated endpoint refusal unexpectedly succeeded"
  [ ! -s "$CASE/home/state/.wake-queue" ] \
    || fail "acknowledged refusal emitted a retry wake storm"
  pass "endpoint refusal preserves its receipt and one retry wake"
}

test_dirty_unlanded_refusal() {
  make_case dirty dirty1
  write_ship_meta dirty1 local-only
  land_task dirty1
  printf 'dirty\n' > "$CASE/wt/uncommitted"
  run_hook local-merged dirty1 && fail "dirty worker retirement unexpectedly succeeded"
  [ -e "$CASE/home/state/dirty1.meta" ] || fail "dirty refusal removed metadata"
  [ -e "$CASE/home/state/dirty1.retirement" ] || fail "dirty refusal lost durable event"
  [ ! -s "$CASE/treehouse.log" ] || fail "dirty refusal reached treehouse cleanup"
  assert_one_retirement_wake
  pass "dirty work refuses and remains retryable"
}

test_clean_unlanded_refusal() {
  make_case clean-unlanded clean1
  write_ship_meta clean1 local-only
  commit_unlanded_task
  arm_local_merge_receipt clean1
  run_hook local-merged clean1 && fail "clean unlanded worker retirement unexpectedly succeeded"
  [ -e "$CASE/home/state/clean1.meta" ] || fail "clean unlanded refusal removed metadata"
  [ ! -e "$CASE/home/state/clean1.retirement" ] || fail "clean unlanded refusal created retirement authority"
  [ ! -s "$CASE/treehouse.log" ] || fail "clean unlanded refusal reached treehouse cleanup"
  assert_one_retirement_wake
  pass "clean unlanded work refuses and remains retryable"
}

test_active_pipeline_preservation() {
  make_case pipeline pipeline1
  write_ship_meta pipeline1 local-only
  land_task pipeline1
  printf 'working\n' > "$CASE/crew-state"
  run_hook local-merged pipeline1 && fail "active pipeline custody unexpectedly retired worker"
  [ -e "$CASE/home/state/pipeline1.meta" ] || fail "active pipeline refusal removed metadata"
  [ ! -s "$CASE/treehouse.log" ] || fail "active pipeline refusal reached destructive cleanup"
  assert_one_retirement_wake
  pass "active pipeline custody preserves worker"
}

test_scout_gates() {
  make_case scout-gates scout1
  write_scout_meta scout1
  run_hook scout-complete scout1 && fail "scout without report unexpectedly retired"
  [ -e "$CASE/home/state/scout1.meta" ] || fail "missing-report refusal removed scout"
  mkdir -p "$CASE/home/data/scout1"
  printf 'report\n' > "$CASE/home/data/scout1/report.md"
  sed -i.bak '/decisions_reviewed=/d' "$CASE/home/state/scout1.meta"
  run_hook scout-complete scout1 && fail "scout with unreviewed decisions unexpectedly retired"
  [ -e "$CASE/home/state/scout1.meta" ] || fail "decision-gate refusal removed scout"
  pass "scout report and decision gates are both required"
}

test_recycled_endpoint_refusal() {
  make_case recycled-endpoint recycle1
  write_ship_meta recycle1 local-only
  land_task recycle1
  printf 'working\n' > "$CASE/crew-state"
  run_hook local-merged recycle1 && fail "active task unexpectedly retired before endpoint recycle"
  sed -i.bak 's#window=firstmate:fm-recycle1#window=other:fm-recycle1#; s#spawn_gen=one#spawn_gen=two#' \
    "$CASE/home/state/recycle1.meta"
  printf 'done\n' > "$CASE/crew-state"
  run_hook recover && fail "recycled endpoint recovery unexpectedly succeeded"
  [ -e "$CASE/home/state/recycle1.meta" ] || fail "recycled endpoint refusal removed metadata"
  [ ! -s "$CASE/treehouse.log" ] || fail "recycled endpoint reached destructive cleanup"
  pass "recycled endpoint identity cannot authorize retirement"
}

test_missing_spawn_generation_refusal() {
  make_case missing-spawn missing1
  write_ship_meta missing1 local-only
  land_task missing1
  sed -i.bak '/spawn_gen=/d' "$CASE/home/state/missing1.meta"
  run_hook local-merged missing1 && fail "missing spawn incarnation unexpectedly authorized retirement"
  [ -e "$CASE/home/state/missing1.meta" ] || fail "missing spawn refusal removed metadata"
  [ ! -e "$CASE/home/state/missing1.retirement" ] || fail "missing spawn refusal created retirement authority"
  [ ! -s "$CASE/treehouse.log" ] || fail "missing spawn refusal reached treehouse cleanup"
  assert_one_retirement_wake
  pass "missing spawn incarnation refuses without manufacturing identity"
}

test_secondmate_exclusion() {
  make_case secondmate second1
  fm_write_meta "$CASE/home/state/second1.meta" \
    'window=firstmate:fm-second1' 'endpoint_task_id=second1' \
    "worktree=$CASE/wt" "project=$CASE/project" \
    'kind=secondmate' 'mode=secondmate' 'spawn_gen=one'
  run_hook local-merged second1 && fail "secondmate unexpectedly entered retirement hook"
  [ -e "$CASE/home/state/second1.meta" ] || fail "secondmate exclusion removed metadata"
  [ ! -s "$CASE/treehouse.log" ] || fail "secondmate exclusion reached cleanup"
  pass "persistent secondmates remain excluded"
}

test_duplicate_idempotence() {
  make_case duplicate duplicate1
  write_ship_meta duplicate1 local-only
  land_task duplicate1
  run_hook local-merged duplicate1 || fail "first duplicate-event retirement failed"
  run_hook local-merged duplicate1 || fail "second duplicate-event call was not idempotent"
  [ "$(wc -l < "$CASE/treehouse.log" | tr -d ' ')" = 1 ] || fail "duplicate event repeated destructive cleanup"
  pass "duplicate retirement event is idempotent"
}

test_restart_recovery() {
  make_case restart restart1
  write_ship_meta restart1 local-only
  land_task restart1
  export FM_TREEHOUSE_FAIL_ONCE="$CASE/return-fails-once"
  run_hook local-merged restart1 && fail "interrupted retirement unexpectedly reported success"
  unset FM_TREEHOUSE_FAIL_ONCE
  [ -e "$CASE/home/state/restart1.retirement" ] || fail "interrupted retirement lost durable event"
  run_hook recover || fail "recovery did not finish interrupted retirement"
  [ ! -e "$CASE/home/state/restart1.meta" ] || fail "recovery left retired metadata"
  [ ! -e "$CASE/home/state/restart1.retirement" ] || fail "recovery left retirement event"
  pass "interrupted retirement recovers after restart"
}

test_backend_close_boundary_is_delegated() {
  make_case herdr-boundary herdr1
  write_scout_meta herdr1 herdr
  mkdir -p "$CASE/home/data/herdr1"
  printf 'report\n' > "$CASE/home/data/herdr1/report.md"
  # The existing Herdr teardown suite owns exact pane-only close behavior.
  # This hook-level regression proves the hook does not introduce a second
  # backend cleanup path or a force argument when it delegates.
  run_hook scout-complete herdr1 || fail "Herdr-boundary scout did not delegate through normal teardown"
  grep -Fq 'pane close w1:p1 --session lab' "$CASE/herdr.log" \
    || fail "Herdr retirement did not close the exact pane"
  [ ! -s "$CASE/tmux.log" ] || fail "Herdr retirement fell back to tmux cleanup"
  assert_no_grep '--force' "$CASE/herdr.log" "retirement hook introduced a force cleanup argument"
  pass "Herdr cleanup remains delegated to exact pane-only teardown"
}

test_done_before_merge_preserves
test_merged_clean_success
test_local_landing_recovery
test_validated_pr_merge_success
test_pr_refusal_preserves_receipt
test_dirty_unlanded_refusal
test_clean_unlanded_refusal
test_active_pipeline_preservation
test_scout_gates
test_recycled_endpoint_refusal
test_missing_spawn_generation_refusal
test_secondmate_exclusion
test_duplicate_idempotence
test_restart_recovery
test_backend_close_boundary_is_delegated

echo "all worker retirement tests passed"
