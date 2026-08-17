#!/usr/bin/env bash
# The job store behind background investigations, kept apart from
# bin/omantra-investigate so it can be exercised without an agent, a desktop or
# a network. See test/test_investigate.sh. Needs slugify() from lib/project.sh
# and the paths from lib/config.sh.
#
# One directory per investigation under $OMANTRA_INVESTIGATIONS:
#
#   <YYYYmmdd-HHMMSS>-<slug>/
#     meta.json   {id, subject, origin, started, pid, finished, exit, read}
#     report.md   the agent's answer — its stdout, nothing else
#     log         the agent's stderr, for when the answer is empty
#
# A directory rather than a row in a database because the interesting artefact
# is a markdown file: `cat`, `grep` and the file manager all work on this store
# without knowing it is one.

# The id, and therefore the directory name. The timestamp leads so a plain sort
# is newest-last, and slugify() is what keeps a subject the model wrote — or a
# subject a user pasted — from naming a directory outside the store.
#
# The slug can legitimately end up empty ("???" as a subject), which would leave
# a directory ending in a hyphen; `untitled` is the floor.
job_id() {
  local subject="${1:-}" slug stamp
  slug="$(slugify "$subject")"
  [ -z "$slug" ] && slug="untitled"
  stamp="${2:-$(date +%Y%m%d-%H%M%S)}"
  printf '%s-%s' "$stamp" "$slug"
}

# Checked rather than re-slugified: this function is reached from the command
# line and from IPC, and neither is trusted to be handing over something job_id
# made — but slugify() truncates at 50 characters, and an id is longer than that
# whenever the subject is, so cleaning the input here would quietly point at a
# directory that does not exist. Nothing but an id job_id could have produced is
# accepted, which rules out slashes, dots and everything else that could leave
# the store.
job_dir() {
  local id="${1:-}"
  [[ "$id" =~ ^[0-9]{8}-[0-9]{6}-[a-z0-9-]+$ ]] || return 1
  printf '%s/%s' "$OMANTRA_INVESTIGATIONS" "$id"
}

# running | done | failed | abandoned, derived rather than stored.
#
# A status field written by the job itself is a lie the moment the job is killed
# — SIGKILL runs no exit trap — and "1 agent working" that never goes away is
# worse than no indicator at all. So `finished` in meta.json is the only claim
# trusted, and when it is absent the question is put to the kernel.
job_status() {
  local dir="${1:-}" meta finished exit_code pid
  meta="$dir/meta.json"
  [ -r "$meta" ] || return 1

  finished="$(jq -r '.finished // ""' "$meta" 2>/dev/null)" || return 1
  if [ -n "$finished" ]; then
    exit_code="$(jq -r '.exit // 1' "$meta" 2>/dev/null)"
    [ "$exit_code" = "0" ] && { printf 'done'; return 0; }
    printf 'failed'
    return 0
  fi

  pid="$(jq -r '.pid // ""' "$meta" 2>/dev/null)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    printf 'running'
  else
    # Started, never finished, and nothing is running: the machine rebooted, or
    # something killed it. Whatever the agent had written is still there.
    printf 'abandoned'
  fi
}

# Every job, newest first, as one JSON array — for `list --json`, the widget and
# the reader.
#
# A directory whose meta.json is missing or unparseable is skipped rather than
# failing the whole listing: `start` writes the file after it makes the
# directory, so there is a window in which one exists without the other, and a
# bar widget that shows nothing because one job is half-written is a bad trade.
jobs_json() {
  local dir id status meta

  [ -d "$OMANTRA_INVESTIGATIONS" ] || { printf '[]'; return 0; }

  {
    # Reverse sort on the name, which begins with the timestamp: newest first
    # without asking the filesystem for mtimes it may not have kept.
    for dir in "$OMANTRA_INVESTIGATIONS"/*/; do
      [ -d "$dir" ] || continue
      printf '%s\n' "${dir%/}"
    done | sort -r
  } | while IFS= read -r dir; do
    meta="$dir/meta.json"
    jq -e . "$meta" >/dev/null 2>&1 || continue
    status="$(job_status "$dir")" || continue
    id="${dir##*/}"
    jq -c --arg id "$id" --arg dir "$dir" --arg status "$status" \
       --argjson report "$([ -s "$dir/report.md" ] && echo true || echo false)" \
       '{id: $id, dir: $dir, status: $status, report: $report,
         subject: (.subject // $id), origin: (.origin // ""),
         started: (.started // 0), finished: (.finished // 0),
         exit: (.exit // null), read: (.read != null)}' "$meta"
  done | jq -sc '.'
}

# Keep the newest $OMANTRA_INVESTIGATIONS_KEEP, oldest out first. A running job
# is never deleted however old it is — the agent still has the directory open,
# and a report that vanishes mid-write is a bug report about the wrong thing.
prune_jobs() {
  local dir kept=0 status

  [ -d "$OMANTRA_INVESTIGATIONS" ] || return 0

  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    status="$(job_status "$dir" 2>/dev/null || echo abandoned)"
    if [ "$status" = "running" ]; then
      continue
    fi
    kept=$((kept + 1))
    if [ "$kept" -gt "$OMANTRA_INVESTIGATIONS_KEEP" ]; then
      # Guarded rather than trusted: this is an `rm -rf` built from a glob, and
      # the one thing worth checking twice is that it is still inside the store.
      case "$dir" in "$OMANTRA_INVESTIGATIONS"/?*) rm -rf "$dir" ;; esac
    fi
  done < <(for dir in "$OMANTRA_INVESTIGATIONS"/*/; do
             [ -d "$dir" ] || continue
             printf '%s\n' "${dir%/}"
           done | sort -r)
}

# The newest job of any status, or non-zero when the store is empty. What
# `omantra-investigate show` means with no argument, because the report you want
# is almost always the one that just landed.
latest_job() {
  local id
  id="$(jobs_json | jq -r '.[0].id // empty')"
  [ -z "$id" ] && return 1
  printf '%s' "$id"
}

# The newest job that has ended and has not been opened yet — what the bar
# button means by "report done" or "report failed", and therefore what a click
# on it opens. Read is per job rather than one "everything up to here"
# timestamp, so opening one of three does not silently mark the other two as
# seen.
#
# A job that ended without a report counts. It is the case with the least on
# screen and the most to explain, and the panel has its log to show; leaving it
# out here was what made a failed investigation a notification's business
# instead of the bar's.
newest_unread() {
  local id
  id="$(jobs_json | jq -r 'map(select(.status != "running" and .read == false))
                           | .[0].id // empty')"
  [ -z "$id" ] && return 1
  printf '%s' "$id"
}
