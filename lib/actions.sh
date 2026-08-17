#!/usr/bin/env bash
# The action table, and the JSON schema generated from it. Sourced by
# bin/omantra, which supplies the matching do_<name> functions; kept apart from
# it so the schema can be exercised without a model, a desktop or a network.
# See test/test_actions.sh. Needs slugify() from lib/project.sh.
#
# The schema is a union — one object per action — rather than one flat object
# offering every field to every action. Flat worked while both actions wanted
# the same two fields and stops working the moment they differ: a model shown
# `name`, `prompt` and `number` on every action, and told to leave the
# irrelevant ones empty, will sooner or later fill the wrong one. A union gives
# each action exactly its own slots, so "workspace three" cannot come back with
# a project name attached — the grammar has nowhere to put one — and the model
# is never asked to emit a field whose only correct value is "".
#
# It also puts `action` first in every branch, which is what makes the union
# cheap to sample: the alternatives share the prefix `{"action":"` and diverge
# on the name, so choosing the action is choosing the rest of the shape.

# ---- Fields -----------------------------------------------------------------
#
# One row per slot an action can ask for:
#
#   key | type | what to tell the model it is for
#
# Types:
#   slug             a string, re-slugified in bash before use
#   string           free text
#   integer:MIN:MAX  a whole number, range-checked in bash before use
#   enum:A,B,C       one of a fixed set of words, checked in bash before use
#
# The type drives both the JSON schema the grammar sampler enforces and the
# re-validation in sanitise_field below, because the schema constrains the
# shape of the reply and not its contents.
#
# Descriptions are per field rather than per action, so keep them about the
# slot; what the slot means for a particular action belongs in that action's
# sentence in ACTIONS.
FIELDS=(
  "name|slug|short kebab-case slug naming the subject of the request. Lowercase letters, digits and hyphens only: \"a todo app\" -> \"todo-app\". For a theme or an application, copy the name from the list above rather than inventing one."
  "prompt|string|a first instruction to hand a coding agent, written in the imperative and expanded into a useful brief of one or two sentences."
  "number|integer:1:10|the workspace the user named, as a digit."
  "switch|enum:night-light,do-not-disturb,stay-awake,screensaver,bar,transparency,mute|which switch the instruction is about. night-light warms the screen colour for the evening; do-not-disturb silences notifications; stay-awake stops the screen locking or sleeping; screensaver is the idle animation; bar is the strip across the top of the screen; transparency is how see-through windows are; mute silences the audio."
  "kind|enum:screenshot,screen-recording|whether the user asked for a still picture of the screen or a video of it."
  "direction|enum:louder,quieter|louder when the instruction asks for more sound, quieter when it asks for less."
  "level|integer:0:100|the percentage the sound should end up at — \"forty percent\" is 40, \"half\" is 50, \"all the way up\" is 100."
  "query|string|what to look up, phrased as it would be typed into a search box."
  "topic|string|the question to research, written out as a full question or instruction rather than as keywords. The subject has to be the one the user named: copy their subject over whatever it is, and do not narrow it, generalise it, or replace it with a subject of your own. No examples are given here on purpose — a model shown one tends to research it."
)

# ---- Actions ----------------------------------------------------------------
#
# One row per action:
#
#   name | fields | the sentence that teaches the model when to pick it
#
# `fields` is a comma-separated list of FIELDS keys, or empty for an action
# that needs no slots. The JSON schema, the system prompt and the dispatch are
# all generated from this table, so adding an action is a row here plus a
# matching do_<name> function in bin/omantra — never three edits that have to
# agree.
#
# Keep them non-destructive; nothing here asks for confirmation.
ACTIONS=(
  "new_project|name,prompt|the user wants to start something that does not exist yet."
  "open_project|name,prompt|the user names an existing project to resume work on. The name is the project's own, as its directory is called, without the word that says it is a project — \"the omantra project\" is omantra."
  "open_app|name|the user names a program to launch — one of the installed applications listed below. An application is a program that opens a window; a project is a directory to work in, so \"open the todo app project\" is open_project and \"open Chromium\" is this."
  "set_theme|name|the user wants to change how the desktop looks — its theme, its colours, light or dark — or simply names one of the installed themes listed below."
  "focus_workspace|number|the user wants to go to another workspace themselves, and nothing is carried there — \"workspace three\", \"go to two\", \"take me back to the first one\". A workspace is always identified by a number, so only pick this when the instruction contains one; the verb alone means nothing, since \"switch to\" is how a theme gets named too."
  "move_to_workspace|number|the user wants the window they are looking at sent to another workspace, staying where they are — \"send this to three\", \"move it to workspace two\". Only when the instruction names the window or says this or it; a request to go somewhere yourself is focus_workspace."
  "fullscreen||the user wants the current window to fill the screen, or to stop filling it."
  "toggle|switch|the user wants to flip one of the desktop switches the switch field lists, and nothing else — night light, do not disturb, staying awake, the screensaver, the bar, window transparency, the sound being muted."
  "capture|kind|the user wants a picture or a video of their screen — \"take a screenshot\", \"start recording\"."
  "set_volume|level|the user names the level the sound should end up at — \"volume to forty percent\", \"put it at half\". Only when a level is actually named."
  "nudge_volume|direction|the user wants more or less sound without naming a level — \"turn it up\", \"louder\", \"a bit quieter\", \"too loud\"."
  "web_search|query|the user wants a search page opened on something — \"search for\", \"look up\", \"google\" — and has not named a project, an application or a theme. This only opens a browser on the words and leaves the reading to the user, so pick it when they want to be *shown* results rather than told an answer; a request to find something out is investigate."
  "investigate|topic|the user wants a subject researched and written up — \"look into\", \"research\", \"find out how\", \"figure out whether\", \"tell me about\", any question that wants an answer rather than a list of links. It hands the question to an agent that reads for a few minutes in the background and comes back with a report, so it fits anything too large for a search box, and it is the right pick whenever the instruction is phrased as a question."
  "unknown||the instruction fits none of those, or is too vague to act on."
)

# ---- Reading the tables -----------------------------------------------------

field_keys() { printf '%s\n' "${FIELDS[@]%%|*}"; }

# "type|description" for a key, or non-zero if there is no such field.
field_row() {
  local row
  for row in "${FIELDS[@]}"; do
    [ "${row%%|*}" = "$1" ] && { printf '%s' "${row#*|}"; return 0; }
  done
  return 1
}

field_type() { local r; r="$(field_row "$1")" || return 1; printf '%s' "${r%%|*}"; }
field_desc() { local r; r="$(field_row "$1")" || return 1; printf '%s' "${r#*|}"; }

action_names() { printf '%s\n' "${ACTIONS[@]%%|*}"; }

action_row() {
  local row
  for row in "${ACTIONS[@]}"; do
    [ "${row%%|*}" = "$1" ] && { printf '%s' "$row"; return 0; }
  done
  return 1
}

# The fields one action declares, one per line — nothing at all for a slotless
# action, which is the case the `sed` guards: an empty list would otherwise
# read back as a single empty field name.
action_fields() {
  local row rest
  row="$(action_row "$1")" || return 1
  rest="${row#*|}"
  printf '%s\n' "${rest%%|*}" | tr ',' '\n' | sed '/^[[:space:]]*$/d'
}

# Every field some action declares, in FIELDS order. The prompt describes only
# these, so a field added to the table but not yet used by an action costs the
# model no attention.
used_fields() {
  local declared action key
  declared="$(while IFS= read -r action; do action_fields "$action"; done < <(action_names))"
  while IFS= read -r key; do
    if grep -qxF "$key" <<<"$declared"; then
      printf '%s\n' "$key"
    fi
  done < <(field_keys)
}

# ---- The prompt -------------------------------------------------------------

# Each action with the slots it takes, so the sentence that picks the action
# and the list of what to fill in arrive together.
action_help() {
  local row action rest fields
  for row in "${ACTIONS[@]}"; do
    action="${row%%|*}"
    rest="${row#*|}"
    fields="${rest%%|*}"
    if [ -n "$fields" ]; then
      printf -- '- %s (%s): %s\n' "$action" "${fields//,/, }" "${rest#*|}"
    else
      printf -- '- %s: %s\n' "$action" "${rest#*|}"
    fi
  done
}

field_help() {
  local key
  while IFS= read -r key; do
    printf -- '- %s: %s\n' "$key" "$(field_desc "$key")"
  done < <(used_fields)
}

# ---- The schema -------------------------------------------------------------

field_schema() {
  local key="$1" type desc min max members
  type="$(field_type "$key")" || return 1
  desc="$(field_desc "$key")"
  case "$type" in
    slug|string)
      jq -nc --arg d "$desc" '{type:"string", description:$d}'
      ;;
    integer:*:*)
      min="${type#integer:}"
      max="${min#*:}"
      min="${min%%:*}"
      jq -nc --arg d "$desc" --argjson min "$min" --argjson max "$max" \
        '{type:"integer", minimum:$min, maximum:$max, description:$d}'
      ;;
    enum:*)
      # The members go in the schema rather than only in the description, so
      # the grammar can only emit one of them — the same trick set_theme plays
      # with the installed theme list, for a set small enough to write down.
      IFS=',' read -r -a members <<<"${type#enum:}"
      jq -nc --arg d "$desc" '{type:"string", enum:$ARGS.positional, description:$d}' \
        --args "${members[@]}"
      ;;
    *)
      return 1
      ;;
  esac
}

# The whole reply schema: one branch per action, each requiring `action` plus
# exactly the fields that action declares, and forbidding everything else.
action_schema() {
  local action key props required schema
  while IFS= read -r action; do
    props='{}'
    required='[]'
    while IFS= read -r key; do
      schema="$(field_schema "$key")" || return 1
      props="$(jq -c --arg k "$key" --argjson s "$schema" '. + {($k): $s}' <<<"$props")"
      required="$(jq -c --arg k "$key" '. + [$k]' <<<"$required")"
    done < <(action_fields "$action")

    jq -nc --arg a "$action" --argjson p "$props" --argjson r "$required" \
      '{type: "object",
        properties: ({action: {const: $a}} + $p),
        required: (["action"] + $r),
        additionalProperties: false}'
  done < <(action_names) | jq -sc '{oneOf: .}'
}

# ---- Coming back ------------------------------------------------------------

# The schema constrains the shape of the reply, not its contents, and the thing
# enforcing it is the model's own sampler — so every value is checked again
# here, on the near side of the wire, where a bad one can only become a failure
# rather than an action. `slug` is the one that matters most: it is what keeps a
# hallucinated `../` inside $OMANTRA_PROJECTS.
#
# Prints the value to use; non-zero when there isn't one.
sanitise_field() {
  local key="$1" value="$2" type min max members member
  type="$(field_type "$key")" || return 1
  case "$type" in
    slug)
      slugify "$value"
      ;;
    string)
      printf '%s' "$value"
      ;;
    integer:*:*)
      min="${type#integer:}"
      max="${min#*:}"
      min="${min%%:*}"
      case "$value" in ''|*[!0-9]*) return 1 ;; esac
      [ "$value" -ge "$min" ] && [ "$value" -le "$max" ] || return 1
      printf '%s' "$value"
      ;;
    enum:*)
      IFS=',' read -r -a members <<<"${type#enum:}"
      for member in "${members[@]}"; do
        [ "$member" = "$value" ] && { printf '%s' "$value"; return 0; }
      done
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# The check `topic` needs and no schema can do for it.
#
# Every other slot is checked against something: a slug is re-slugified, a
# number has a range, an enum has members. `topic` is free text handed to an
# agent that will read for three minutes on the strength of it, and the one way
# it goes wrong is the one a schema cannot see — a fluent, well-formed question
# about a subject the user never mentioned. It happened with an example in the
# field description, which a small model researched instead of listening; the
# examples are gone, but the failure mode is the model's, not the wording's.
#
# So the transcript gets a vote. A rewording of what was said shares a word of
# substance with it; a question about something else does not. Words of three
# letters or fewer are ignored on both sides, since "how" and "the" match
# everything and would wave the wrong subject straight through.
#
# Prints the topic to use: the model's when it is grounded in what was said,
# the transcript itself when it isn't. Handing the agent "look into react"
# unedited is a worse question about the right subject, which is the trade this
# makes every time it fires.
grounded_topic() {
  local topic="$1" said="$2" word said_words
  said_words=" $(printf '%s' "$said" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' ' ') "
  # shellcheck disable=SC2013  # word splitting is the point: one word per pass.
  for word in $(printf '%s' "$topic" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' ' '); do
    [ "${#word}" -ge 4 ] || continue
    case "$said_words" in
      *" $word "*) printf '%s' "$topic"; return 0 ;;
    esac
  done
  printf '%s' "$said"
}
