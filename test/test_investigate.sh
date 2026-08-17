#!/usr/bin/env bash
# The job store behind background investigations: ids, statuses, listing,
# pruning, and one end-to-end start with a stub agent.
#
# No real agent, no desktop and no network — OMANTRA_INVESTIGATOR is pointed at
# a script that prints markdown, which is the whole reason the runner takes the
# agent as a setting rather than naming `claude` in the dispatch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/test/lib.sh"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

export OMANTRA_CONFIG_FILE=/dev/null
export OMANTRA_STATE_DIR="$fixture/state"
export OMANTRA_INVESTIGATIONS="$fixture/state/investigations"

. "$ROOT/lib/config.sh"
. "$ROOT/lib/project.sh"
. "$ROOT/lib/investigate.sh"

mkdir -p "$OMANTRA_INVESTIGATIONS"

# A job dir as `start` would leave it. `pid` empty means "not started"; a
# `finished` makes it a result.
make_job() {
  local id="$1" pid="${2:-}" finished="${3:-}" code="${4:-0}" dir
  dir="$OMANTRA_INVESTIGATIONS/$id"
  mkdir -p "$dir"
  jq -n --arg id "$id" --arg subject "subject of $id" --arg pid "$pid" \
        --arg finished "$finished" --argjson exit "$code" \
    '{id: $id, subject: $subject, origin: "/tmp", started: 1}
     + (if $pid == "" then {} else {pid: ($pid|tonumber)} end)
     + (if $finished == "" then {} else {finished: ($finished|tonumber), exit: $exit} end)' \
    > "$dir/meta.json"
  printf '%s' "$dir"
}

echo "lib/investigate.sh — ids"

assert_eq "20250101-000000-todo-app" "$(job_id "Todo App" 20250101-000000)" \
  "an id is the timestamp and the slugified subject"
assert_eq "20250101-000000-untitled" "$(job_id "???" 20250101-000000)" \
  "a subject that slugs to nothing still gets a directory name"

# The security boundary, one domain over from find_project: nothing a model or
# a paste can put in a subject may name a directory outside the store.
assert_eq "20250101-000000-etc-passwd" "$(job_id "../../etc/passwd" 20250101-000000)" \
  "path traversal cannot survive into an id"
assert_eq "$OMANTRA_INVESTIGATIONS/20250101-000000-todo-app" \
  "$(job_dir 20250101-000000-todo-app)" "job_dir resolves an id job_id could have made"
assert_fails "job_dir refuses an empty id" job_dir ""
assert_fails "job_dir refuses a path" job_dir "../../etc/passwd"
assert_fails "job_dir refuses a bare slug with no timestamp" job_dir "todo-app"
assert_fails "job_dir refuses a traversal dressed as an id" job_dir "20250101-000000-a/../.."

# The bug this guards: an id is a 16-character timestamp plus a slug that
# slugify truncates at 50, so it is routinely longer than 50 itself. Cleaning
# the id here rather than checking it pointed at a directory that did not exist,
# and every `show` of a long-titled report failed.
long_id="$(job_id "$(printf 'endpointing %.0s' {1..12})" 20250101-000000)"
assert_eq "$OMANTRA_INVESTIGATIONS/$long_id" "$(job_dir "$long_id")" \
  "a long id survives job_dir intact"

echo
echo "statuses are derived, not stored"

running_dir="$(make_job 20250102-000000-running "$$")"
assert_eq "running" "$(job_status "$running_dir")" "a live pid is running"

# The case a stored status field gets wrong: SIGKILL runs no exit trap, so a
# job whose process is gone with no `finished` has to be read off the kernel.
dead_dir="$(make_job 20250102-000001-dead 999999)"
assert_eq "abandoned" "$(job_status "$dead_dir")" "a dead pid with no finish is abandoned"

done_dir="$(make_job 20250102-000002-done 999999 200 0)"
assert_eq "done" "$(job_status "$done_dir")" "a zero exit is done"

failed_dir="$(make_job 20250102-000003-failed 999999 200 124)"
assert_eq "failed" "$(job_status "$failed_dir")" "a non-zero exit is failed"

assert_fails "a directory with no meta.json has no status" job_status "$fixture/nowhere"

echo
echo "listing"

echo "# a report" > "$done_dir/report.md"

json="$(jobs_json)"
assert_eq "0" "$(jq -e . >/dev/null 2>&1 <<<"$json" && echo 0 || echo 1)" \
  "the listing is valid JSON"
assert_eq "4" "$(jq 'length' <<<"$json")" "every job is listed"
assert_eq "20250102-000003-failed" "$(jq -r '.[0].id' <<<"$json")" \
  "newest first"
assert_eq "true" "$(jq -r '.[] | select(.id == "20250102-000002-done") | .report' <<<"$json")" \
  "a job with a report says so"
assert_eq "false" "$(jq -r '.[] | select(.id == "20250102-000000-running") | .report' <<<"$json")" \
  "a job without one says that"

# `start` makes the directory before it writes the file, so there is a window in
# which one exists without the other. A bar widget that shows nothing because
# one job is half-written would be the worse failure.
mkdir -p "$OMANTRA_INVESTIGATIONS/20250102-000004-halfwritten"
assert_eq "4" "$(jobs_json | jq 'length')" "a half-written job is skipped, not fatal"
echo 'not json' > "$OMANTRA_INVESTIGATIONS/20250102-000004-halfwritten/meta.json"
assert_eq "4" "$(jobs_json | jq 'length')" "an unparseable meta.json is skipped too"
rm -rf "$OMANTRA_INVESTIGATIONS/20250102-000004-halfwritten"

assert_eq "20250102-000003-failed" "$(latest_job)" "the newest job is the default one to show"

echo
echo "pruning"

OMANTRA_INVESTIGATIONS_KEEP=2
prune_jobs

assert_eq "0" "$([ -d "$OMANTRA_INVESTIGATIONS/20250102-000001-dead" ] && echo 1 || echo 0)" \
  "the oldest finished job is deleted"
assert_eq "1" "$([ -d "$OMANTRA_INVESTIGATIONS/20250102-000003-failed" ] && echo 1 || echo 0)" \
  "the newest is kept"

# A running agent still has the directory open, and a report that vanishes
# mid-write is a bug report about the wrong thing.
assert_eq "1" "$([ -d "$OMANTRA_INVESTIGATIONS/20250102-000000-running" ] && echo 1 || echo 0)" \
  "a running job is never pruned, however old"

OMANTRA_INVESTIGATIONS_KEEP=50

echo
echo "bin/omantra-investigate, with a stub agent"

rm -rf "$OMANTRA_INVESTIGATIONS"
mkdir -p "$OMANTRA_INVESTIGATIONS"

# Sleeps, so `start` returning before the report exists is observable rather
# than a race the test wins by accident.
stub="$fixture/stub-agent"
cat > "$stub" <<'EOF'
#!/usr/bin/env bash
sleep 1
echo "# Findings"
echo
echo "The answer."
EOF
chmod +x "$stub"

export OMANTRA_INVESTIGATOR="$stub"
export OMANTRA_NOTIFY=false
export PATH="$fixture/bin:$PATH"
# No shell to talk to in a test, and ping_widget must not care.
mkdir -p "$fixture/bin"

id="$("$ROOT/bin/omantra-investigate" start "How does endpointing work")"
assert_eq "$id" "$(basename "$(printf '%s' "$id")")" "start prints one job id"
assert_eq "running" "$(job_status "$OMANTRA_INVESTIGATIONS/$id")" \
  "start returns while the agent is still working"
assert_eq "1" "$("$ROOT/bin/omantra-investigate" list --json | jq '[.[] | select(.status == "running")] | length')" \
  "list --json reports it as running"

# The stub sleeps for a second; give it two before asking for the report.
sleep 2.5

assert_eq "done" "$(job_status "$OMANTRA_INVESTIGATIONS/$id")" "the job finishes"
assert_eq "# Findings" "$("$ROOT/bin/omantra-investigate" show | head -1)" \
  "show prints the newest report"
assert_eq "false" "$("$ROOT/bin/omantra-investigate" list --json | jq -r '.[0].read')" \
  "a landed report is unread until it is opened"

# `open` hands the panel an id over IPC, so a bad one has to fail here rather
# than as an empty card on the other side of the call.
assert_fails "open refuses an id that is not a job" \
  "$ROOT/bin/omantra-investigate" open 20200101-000000-nope

# Marking read is the store's job, and testable without a desktop: the panel
# calls this the moment it puts a report on screen.
"$ROOT/bin/omantra-investigate" read "$id"
assert_eq "true" "$("$ROOT/bin/omantra-investigate" list --json | jq -r '.[0].read')" \
  "read <id> stamps that report"
assert_eq "" "$(newest_unread || true)" \
  "and it is no longer the newest unread"

# An agent that says nothing and exits 0 is a failure the exit code does not
# report, and an empty panel is the least useful way to find that out.
cat > "$stub" <<'EOF'
#!/usr/bin/env bash
echo "went looking, found nothing" >&2
EOF
silent="$("$ROOT/bin/omantra-investigate" start "A subject with no answer")"
sleep 1.5
assert_eq "failed" "$(job_status "$OMANTRA_INVESTIGATIONS/$silent")" \
  "an empty report is a failure, whatever the agent exited with"
assert_eq "went looking, found nothing" "$("$ROOT/bin/omantra-investigate" log "$silent" | head -1)" \
  "the agent's stderr is kept"
assert_eq "the agent exited 0 without writing a report" \
  "$("$ROOT/bin/omantra-investigate" log "$silent" | tail -1)" \
  "the log says why an empty report counted as a failure"

# A job that failed without writing anything is still news the bar has to
# carry: "report failed" is the surface that replaced the notification, and the
# click behind it needs this job to be what the newest unread one is.
assert_eq "$silent" "$(newest_unread)" \
  "a job that failed without a report is the newest unread news"

"$ROOT/bin/omantra-investigate" read "$silent" >/dev/null
assert_fails "and reading it takes it off the bar like any other" newest_unread

assert_fails "show refuses a job with no report" \
  "$ROOT/bin/omantra-investigate" show "$silent"
assert_fails "an unknown id is not a job" \
  "$ROOT/bin/omantra-investigate" show 20200101-000000-nope
assert_fails "an unknown command fails" "$ROOT/bin/omantra-investigate" nonesuch

summary
