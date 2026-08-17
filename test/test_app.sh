#!/usr/bin/env bash
# The application matcher: desktop entries in, an entry id out. The fixture
# stands in for the XDG application trees, so this needs no desktop, no
# installed programs and no launcher.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/test/lib.sh"
. "$ROOT/lib/project.sh"   # find_app slugifies both sides through slugify

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/user" "$fixture/system"

entry() { # entry <dir> <id> <body...>
  local dir="$1" id="$2"; shift 2
  { printf '[Desktop Entry]\n'; printf '%s\n' "$@"; } > "$fixture/$dir/$id.desktop"
}

entry system org.mozilla.firefox "Type=Application" "Name=Firefox" "Exec=firefox"
entry system code                "Type=Application" "Name=Code"    "Exec=code"
entry system code-oss            "Type=Application" "Name=Code - OSS" "Exec=code-oss"
entry system org.gnome.Nautilus  "Type=Application" "Name=Files"   "Exec=nautilus"
entry user   spotify             "Type=Application" "Name=Spotify" "Exec=spotify"

# The three kinds of entry a launcher menu hides, and so does this.
entry system avahi-discover      "Type=Application" "Name=Avahi Discover" "NoDisplay=true"
entry system removed-app         "Type=Application" "Name=Removed"        "Hidden=true"
entry system some-link           "Type=Link"        "Name=A Link"         "URL=https://example.com"

# A second group with its own Name=, which is what most real entries look like:
# only the [Desktop Entry] one is the application's name.
entry system gimp "Type=Application" "Name=GIMP" "Exec=gimp" \
  "" "[Desktop Action new-window]" "Name=New Window" "Exec=gimp -n"

# A localised name must not shadow the C one — `Name[es]=` sorts before `Name=`
# in the file, so getting this wrong is the natural mistake.
entry system alacritty "Type=Application" "Name[es]=Terminal Alacritty" "Name=Alacritty" "Exec=alacritty"

OMANTRA_APP_DIRS=("$fixture/user" "$fixture/system")
. "$ROOT/lib/app.sh"

echo "lib/app.sh"

# ---- Listing ----------------------------------------------------------------

assert_eq "Alacritty Code Code - OSS Files Firefox GIMP Spotify" \
  "$(app_names | tr '\n' ' ' | sed 's/ $//')" \
  "lists both trees, sorted, hidden entries left out"

assert_eq "" "$(app_names | grep -i 'avahi\|removed\|a link' || true)" \
  "NoDisplay, Hidden and non-application entries never appear"

assert_eq "GIMP" "$(app_entries | awk -F'|' '$1 == "gimp" { print $2 }')" \
  "a desktop action's Name= does not shadow the application's"

assert_eq "Alacritty" "$(app_entries | awk -F'|' '$1 == "alacritty" { print $2 }')" \
  "a localised Name[xx]= does not shadow the C one"

# ---- Matching ---------------------------------------------------------------

assert_eq "spotify" "$(find_app spotify)" "exact display name wins"
assert_eq "org.gnome.Nautilus" "$(find_app files)" \
  "matches on the display name, not the reverse-DNS id"
assert_eq "org.mozilla.firefox" "$(find_app firefox)" \
  "matches on a word inside the id when the name does not have it"
assert_eq "code" "$(find_app code)" \
  "exact beats a longer entry it is a prefix of"
assert_eq "code-oss" "$(find_app code-oss)" \
  "the longer one is still reachable by its own name"

# Speech arrives slugified, so this is the shape find_app is really given.
assert_eq "code-oss" "$(find_app "$(slugify 'Code - OSS')")" \
  "a slugified display name matches the entry it came from"

assert_fails "returns non-zero for no match rather than exiting" find_app nosuchapp
assert_fails "returns non-zero for an empty name" find_app ""

assert_eq "" "$(find_app 'fire*' || true)" "does not treat a name as a glob"
assert_eq "" "$(find_app 'f.refox' || true)" "does not treat a name as a regex"

# The keyword tier: a request that names a job rather than a program. Nautilus
# calls itself Files, so only its Categories can answer "the file manager".
entry system org.gnome.Nautilus "Type=Application" "Name=Files" "Exec=nautilus" \
  "Keywords=folder;manager;explore;disk;filesystem;nautilus;" \
  "Categories=GNOME;GTK;Utility;Core;FileManager;"

assert_eq "org.gnome.Nautilus" "$(find_app file-manager)" \
  "a spoken job title matches an entry's category"
assert_eq "org.gnome.Nautilus" "$(find_app filesystem)" \
  "a keyword matches too"
assert_eq "code" "$(find_app code)" \
  "a keyword never beats a name that matches exactly"

# The category list outruns slugify's 50-character cut, which is why the tier
# does its own folding rather than reusing it.
assert_eq "org.gnome.Nautilus" "$(find_app filemanager)" \
  "a category near the end of a long list is still reachable"

# ---- Titles -----------------------------------------------------------------

assert_eq "Files" "$(app_title org.gnome.Nautilus)" \
  "an id resolves back to what the user would call it"
assert_eq "Code" "$(app_title code)" \
  "an id matches its own row, not the longer one it prefixes"
assert_eq "made-up" "$(app_title made-up)" \
  "an id with no entry falls back to itself"
assert_eq "" "$(app_title '')" "an empty id is empty, not the first entry"

summary
