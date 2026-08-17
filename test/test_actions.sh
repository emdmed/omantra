#!/usr/bin/env bash
# The action table and the schema built from it. Pure string and JSON work, so
# no model, no desktop and no network — which is the point of keeping the table
# in lib/ and only the do_ functions in bin/omantra.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
. "$ROOT/test/lib.sh"
. "$ROOT/lib/project.sh"   # sanitise_field's slug type calls slugify
. "$ROOT/lib/actions.sh"

echo "lib/actions.sh"

schema="$(action_schema)"

# ---- The table is internally consistent -------------------------------------

# The failure this catches is a typo in an action's field list: a slot named
# there but not in FIELDS would reach action_schema as an unbuildable property,
# and the first sign of it would be a request the server rejects.
for action in $(action_names); do
  for key in $(action_fields "$action"); do
    assert_eq "0" "$(field_row "$key" >/dev/null && echo 0 || echo 1)" \
      "$action's field \"$key\" is declared in FIELDS"
  done
done

assert_eq "0" "$(printf '%s' "$schema" | jq -e . >/dev/null 2>&1 && echo 0 || echo 1)" \
  "the schema is valid JSON"

assert_fails "an action that is not in the table has no row" action_row nonesuch

# ---- One branch per action, carrying only its own slots ---------------------

assert_eq "$(action_names | wc -l)" "$(jq '.oneOf | length' <<<"$schema")" \
  "one union branch per action"

assert_eq "action name prompt" \
  "$(jq -r '.oneOf[] | select(.properties.action.const == "new_project")
            | .required | join(" ")' <<<"$schema")" \
  "new_project requires action, name and prompt"

# The whole reason for the union: the slot another action uses is not merely
# optional here, it is absent, so the grammar cannot produce it.
assert_eq "action number" \
  "$(jq -r '.oneOf[] | select(.properties.action.const == "focus_workspace")
            | .required | join(" ")' <<<"$schema")" \
  "focus_workspace requires action and number"

assert_eq "null" \
  "$(jq -r '.oneOf[] | select(.properties.action.const == "focus_workspace")
            | .properties.prompt' <<<"$schema")" \
  "focus_workspace has no prompt property at all"

# The pair most likely to collide: both take one free-text slot, and the only
# thing keeping them apart is that they take *different* slots with different
# descriptions. A `query` on investigate would be the first sign that the two
# rows had been merged by a well-meaning edit.
assert_eq "action topic" \
  "$(jq -r '.oneOf[] | select(.properties.action.const == "investigate")
            | .required | join(" ")' <<<"$schema")" \
  "investigate requires action and topic"

assert_eq "null" \
  "$(jq -r '.oneOf[] | select(.properties.action.const == "investigate")
            | .properties.query' <<<"$schema")" \
  "investigate has no query property — that is web_search's slot"

assert_eq "action" \
  "$(jq -r '.oneOf[] | select(.properties.action.const == "unknown")
            | .required | join(" ")' <<<"$schema")" \
  "a slotless action requires nothing but the action name"

assert_eq "0" \
  "$(jq '[.oneOf[] | select(.additionalProperties != false)] | length' <<<"$schema")" \
  "every branch forbids fields it did not ask for"

# `action` first in each branch is what makes the union cheap to sample: the
# alternatives share a prefix and diverge on the name.
assert_eq "0" \
  "$(jq '[.oneOf[] | select((.properties | keys_unsorted[0]) != "action")] | length' <<<"$schema")" \
  "action is the first property in every branch"

# ---- Typed slots -------------------------------------------------------------

assert_eq "integer 1 10" \
  "$(jq -r '.oneOf[] | select(.properties.action.const == "focus_workspace")
            | .properties.number | "\(.type) \(.minimum) \(.maximum)"' <<<"$schema")" \
  "an integer slot carries its range into the schema"

assert_eq "string" \
  "$(jq -r '.oneOf[] | select(.properties.action.const == "set_theme")
            | .properties.name.type' <<<"$schema")" \
  "a slug slot is a string on the wire"

# An enum's members go in the schema, not only in the description, so the
# grammar itself can only emit one of them.
assert_eq "night-light do-not-disturb stay-awake screensaver bar transparency mute" \
  "$(jq -r '.oneOf[] | select(.properties.action.const == "toggle")
            | .properties.switch.enum | join(" ")' <<<"$schema")" \
  "an enum slot carries its members into the schema"

assert_eq "0" \
  "$(jq -r '[.oneOf[].properties | to_entries[] | select(.key != "action")
            | select((.value.description // "") == "")] | length' <<<"$schema")" \
  "every slot tells the model what it is for"

# ---- Re-validation on the way back ------------------------------------------
#
# The sampler enforcing the schema is the model's own, so nothing above is
# trusted here.

assert_eq "etc-passwd" "$(sanitise_field name '../../etc/passwd')" \
  "a slug slot defangs path traversal"
assert_eq "tokyo-night" "$(sanitise_field name 'Tokyo Night')" \
  "a slug slot lowercases and hyphenates"
assert_eq "3" "$(sanitise_field number 3)" \
  "an in-range integer survives"
assert_eq "make it good" "$(sanitise_field prompt 'make it good')" \
  "a string slot is passed through"

assert_fails "an integer below the range is refused" sanitise_field number 0
assert_fails "an integer above the range is refused" sanitise_field number 11
assert_fails "a word where a number belongs is refused" sanitise_field number three
assert_fails "an empty integer is refused" sanitise_field number ''
assert_fails "a negative integer is refused" sanitise_field number -- -2
assert_eq "mute" "$(sanitise_field switch mute)" \
  "an enum member survives"
assert_fails "a word outside the enum is refused" sanitise_field switch bogus
assert_fails "an enum is matched whole, not by prefix" sanitise_field switch mut
assert_fails "an empty enum value is refused" sanitise_field switch ''
assert_fails "an unknown field has no rule to apply" sanitise_field nonesuch x

# ---- The prompt describes the same table ------------------------------------

assert_eq "$(action_names | wc -l)" "$(action_help | wc -l)" \
  "every action gets a line in the prompt"

# The sentence itself is prompt-tuning and changes; that it arrives with its
# slot list attached is the contract.
assert_eq "- focus_workspace (number):" \
  "$(action_help | grep '^- focus_workspace' | cut -d' ' -f1-3)" \
  "an action's line names the slots it takes"

assert_eq "- new_project (name, prompt):" \
  "$(action_help | grep '^- new_project' | cut -d' ' -f1-4)" \
  "a two-slot action lists both, comma-separated"

assert_eq "- unknown: the instruction fits none of those, or is too vague to act on." \
  "$(action_help | grep '^- unknown')" \
  "a slotless action's line has no empty bracket"

assert_eq "$(field_keys | tr '\n' ' ' | sed 's/ $//')" \
  "$(used_fields | tr '\n' ' ' | sed 's/ $//')" \
  "every field in the table is used by some action, in table order"

# ---- The dispatch has a function for every row ------------------------------
#
# A row added here without its do_ function falls through to do_unknown, which
# copies the words to the clipboard and says "not understood" — a failure that
# looks exactly like a mishearing and is therefore debugged in the wrong half.
for action in $(action_names); do
  if grep -q "^do_$action()" "$ROOT/bin/omantra"; then
    pass "$action has a do_ function in bin/omantra"
  else
    fail "$action is in the table but bin/omantra has no do_$action"
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
done

summary
