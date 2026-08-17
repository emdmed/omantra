#!/usr/bin/env bash
# Resolving a spoken program name to an application the machine actually has.
# Sourced by bin/omantra; exercised without a desktop by test/test_app.sh.
#
# The same shape as lib/theme.sh, one domain over: the list goes into the system
# prompt, the model picks a name from it, and bash decides again whether that
# name is an application before anything is launched. So an app the model has
# heard of but you have not installed is a "no application matches" failure
# rather than a failed command.
#
# Desktop entries are the identity because they are what a launcher launches:
# `foo.desktop` is a thing `uwsm app` or `gtk-launch` can be handed, whereas the
# binary behind it may be a wrapper, a flatpak, or not on PATH at all.

# Set only if the caller has not: the tests point this at a fixture. The order
# is user tree first, which is the order XDG says user entries override system
# ones in.
if [ -z "${OMANTRA_APP_DIRS+set}" ]; then
  OMANTRA_APP_DIRS=(
    "${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    "${XDG_DATA_HOME:-$HOME/.local/share}/flatpak/exports/share/applications"
    /var/lib/flatpak/exports/share/applications
    /usr/share/applications
  )
fi

# Every launchable entry, as `id|Display Name|keywords`, deduplicated by id.
#
# The third field is the entry's own Keywords= and Categories=, which is how a
# generic spoken request finds a specific program: nobody says "Nautilus", they
# say "the file manager", and `FileManager` is a category Nautilus already
# declares. It is a last resort in find_app, below the name and the id.
#
# The filtering is what keeps the prompt readable: a bare `ls` of
# /usr/share/applications is mostly things no one would ever ask for out loud —
# NoDisplay entries that exist to own a MIME type, Hidden ones a user has
# removed, and link/directory entries that are not applications at all. Those
# are exactly the ones a launcher menu hides too.
app_entries() {
  local dir
  # shellcheck disable=SC2016  # $0 and $1 in the awk program are awk's fields,
  # not the shell's — the single quotes are what keeps them that way.
  {
    for dir in "${OMANTRA_APP_DIRS[@]}"; do
      [ -d "$dir" ] || continue
      find "$dir" -maxdepth 1 -name '*.desktop' -print0 2>/dev/null
    done
  } | xargs -0 -r awk '
    function emit() {
      if (id != "" && !skip && name != "" && (type == "" || type == "Application"))
        print id "|" name "|" keywords categories
    }
    function reset() {
      id = FILENAME
      sub(/.*\//, "", id)
      sub(/\.desktop$/, "", id)
      name = ""; skip = 0; type = ""; keywords = ""; categories = ""; in_entry = 0
    }
    # A .desktop file can hold several groups and only [Desktop Entry] describes
    # the application itself; the rest are actions ("Open a New Window") with
    # their own Name= lines, which is why the group is tracked at all.
    FNR == 1 { emit(); reset() }
    /^\[/ { in_entry = ($0 == "[Desktop Entry]"); next }
    !in_entry { next }
    # ^Name= and not Name[es]=, so a localised entry does not shadow the C one.
    /^Name=/ { if (name == "") name = substr($0, 6); next }
    /^NoDisplay[ \t]*=[ \t]*true/ { skip = 1; next }
    /^Hidden[ \t]*=[ \t]*true/ { skip = 1; next }
    /^Type=/ { type = substr($0, 6); next }
    /^Keywords=/ { keywords = substr($0, 10); next }
    /^Categories=/ { categories = ";" substr($0, 12); next }
    END { emit() }
  ' | sort -s -t'|' -k1,1 -u
}

# Just the display names, for the system prompt: what a person would say out
# loud is "Firefox", not "firefox.desktop".
app_names() {
  app_entries | cut -d'|' -f2 | sort -u
}

# Resolve a slug to a desktop entry id, widening in three steps: the name or id
# exactly, then either as a substring, then the entry's own keywords.
#
# Both the display name and the id are candidates because speech lands on
# either: "files" is a name, "org.gnome.Nautilus" never gets said but "nautilus"
# is how the same thing is asked for. The keyword tier is what answers a request
# that names a job rather than a program — "the file manager", "a browser",
# "the terminal" — and it is last precisely because it is the vaguest: a program
# that calls itself Files should win over one that merely lists FileManager
# among its categories.
#
# Exact wins outright and only after every candidate has been seen, so "code"
# is not answered with "code-oss" while plain Code is installed. Comparison is
# fixed-string throughout: a model-derived slug is never treated as a pattern.
find_app() {
  local want="$1" id
  [ -z "$want" ] && return 1

  # One awk pass rather than a bash loop: the tiers need every candidate seen
  # before the winner is known, and doing that in bash meant two subprocesses
  # per installed application just to fold case.
  #
  # `want` is compared as it arrives, lowercased but not re-slugified — it is
  # already a slug, and normalising it again would turn a stray "fire*" into a
  # match for Firefox. index() throughout, so it is never a pattern.
  id="$(app_entries | awk -F'|' -v want="$want" '''
    function norm(s,   t) {
      t = tolower(s); gsub(/[^a-z0-9]+/, "-", t)
      sub(/^-/, "", t); sub(/-$/, "", t); return t
    }
    # Hyphens dropped for the keyword tier only: categories are single words by
    # construction, so "file-manager" has to reach "FileManager". Doing this to
    # the name tiers would make "code-oss" and "codeoss" the same program.
    function squash(s,   t) { t = tolower(s); gsub(/[^a-z0-9]/, "", t); return t }
    BEGIN { w = tolower(want); ws = squash(want) }
    {
      idn = norm($1); namen = norm($2)
      if (idn == w || namen == w) { print $1; exact = 1; exit }
      if (part == "" && (index(idn, w) || index(namen, w))) part = $1
      if (kw == "" && $3 != "" && ws != "" && index(squash($3), ws)) kw = $1
    }
    END {
      if (exact) exit          # already printed, before the sweep was cut short
      if (part != "") print part
      else if (kw != "") print kw
    }
  ''')"

  [ -z "$id" ] && return 1
  printf '%s' "$id"
}

# The display name for an id, for the chip — "org.gnome.Nautilus" is not what
# the user called it, and the chip's job is to say what is about to happen in
# the words it was asked in. Falls back to the id when there is no entry.
app_title() {
  local id="${1:-}" line
  [ -z "$id" ] && return 0
  # Matched on the whole first field rather than as a substring, so a shorter id
  # cannot be answered with a longer one's display name.
  line="$(app_entries | awk -F'|' -v id="$id" '$1 == id { print $2; exit }')"
  [ -z "$line" ] && { printf '%s' "$id"; return 0; }
  printf '%s' "$line"
}
