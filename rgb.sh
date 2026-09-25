#!/bin/sh
# rgb.sh - RGB lighting of the machine (motherboard, RAM, GPU, coolers...)
# through a running OpenRGB server. The No RGB bar widget calls it, and it
# works from a terminal too: `rgb.sh help`.
#
# The state lives in ${XDG_STATE_HOME:-~/.local/state}/azeroht-no-rgb.json.
set -eu

state_directory="${XDG_STATE_HOME:-${HOME}/.local/state}"
state_file="${state_directory}/azeroht-no-rgb.json"
server="${NO_RGB_SERVER:-127.0.0.1:6742}"
# With the server up, the client answers in about a second; without it, it
# waits forever.
client_timeout="${NO_RGB_CLIENT_TIMEOUT:-15}"
# restore: right after it starts, the server needs some twenty seconds to
# detect the devices.
restore_timeout="${NO_RGB_RESTORE_TIMEOUT:-90}"
restore_poll_seconds="${NO_RGB_RESTORE_POLL_SECONDS:-3}"
defaults='{"enabled":false,"color":"FF6600","brightness":100,"mode":"static","off":[]}'

usage() {
  cat >&2 <<'EOF'
rgb.sh - RGB lighting through the OpenRGB server

  rgb.sh on | off | toggle
  rgb.sh components                 components found by OpenRGB, as JSON
  rgb.sh component <name> on|off    include or exclude one component
  rgb.sh color <RRGGBB>             color, with or without #
  rgb.sh brightness <0-100>         brightness in %
  rgb.sh mode <static|breathing|spectrum|rainbow>
  rgb.sh restore                    wait for the server, then reapply the state
  rgb.sh status                     saved state, as JSON
  rgb.sh help

color, brightness and mode also turn the lights on. An excluded component
stays dark while the others are lit.
State: ~/.local/state/azeroht-no-rgb.json ($XDG_STATE_HOME when set)
EOF
  exit "$1"
}

# Complete and safe state: defaults for any field that is missing, unreadable
# or out of range (a file edited by hand).
sanitize='
  ($defaults + .) as $state
  | {
      enabled: ($state.enabled == true),
      color: (if ($state.color | type) == "string" and ($state.color | length) == 6
                 and ($state.color | ascii_upcase | explode
                      | all(. as $code | "0123456789ABCDEF" | explode | index($code) != null))
              then ($state.color | ascii_upcase) else $defaults.color end),
      brightness: (if ($state.brightness | type) == "number"
                      and $state.brightness >= 0 and $state.brightness <= 100
                   then ($state.brightness | floor) else $defaults.brightness end),
      mode: (if ["static", "breathing", "spectrum", "rainbow"] | index([$state.mode]) != null
             then $state.mode else $defaults.mode end),
      off: (if ($state.off | type) == "array" then [$state.off[] | strings] | unique else [] end)
    }'

read_state() {
  if [ -r "${state_file}" ] && jq -e 'type == "object"' "${state_file}" >/dev/null 2>&1; then
    jq -c --argjson defaults "${defaults}" "${sanitize}" "${state_file}"
  else
    printf '%s\n' "${defaults}"
  fi
}

# Applies the jq filter given as arguments to the saved state.
write_state() {
  temporary="$(mktemp "${state_file}.XXXXXX")"
  if ! read_state | jq "$@" >"${temporary}"; then
    rm -f "${temporary}"
    exit 1
  fi
  mv "${temporary}" "${state_file}"
}

is_hex_color() {
  case "$1" in
    '' | *[!0-9A-Fa-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 6 ]
}

is_percent() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$1" -le 100 ]
}

# Mode name on the OpenRGB side.
openrgb_mode() {
  case "$1" in
    static) echo "Static" ;;
    breathing) echo "Breathing" ;;
    spectrum) echo "Spectrum Cycle" ;;
    rainbow) echo "Rainbow" ;;
    *) return 1 ;;
  esac
}

# RRGGBB color dimmed to $2 %.
scale_color() {
  red=$((0x$(printf '%s' "$1" | cut -c1-2) * $2 / 100))
  green=$((0x$(printf '%s' "$1" | cut -c3-4) * $2 / 100))
  blue=$((0x$(printf '%s' "$1" | cut -c5-6) * $2 / 100))
  printf '%02X%02X%02X\n' "${red}" "${green}" "${blue}"
}

fail() {
  echo "rgb.sh: $1" >&2
  if command -v notify-send >/dev/null 2>&1; then
    notify-send --app-name="No RGB" "No RGB" "$1" 2>/dev/null || true
  fi
  exit 1
}

unreachable_message="OpenRGB server unreachable (sudo systemctl enable --now openrgb)"

# OpenRGB client, bounded in time.
client() {
  timeout "${client_timeout}" openrgb --client "${server}" "$@" 2>&1 || fail "${unreachable_message}"
}

# Devices seen by the server, one "index<TAB>name<TAB>type" line each (header
# "3: ENE DRAM", then "  Type: DRAM"); fails when the server does not answer.
devices() {
  listing="$(timeout "${client_timeout}" openrgb --client "${server}" --list-devices 2>/dev/null)" || return 1
  printf '%s\n' "${listing}" | while IFS= read -r line; do
    case "${line}" in
      [0-9]*': '*)
        index="${line%%: *}"
        name="${line#*: }"
        case "${index}" in
          *[!0-9]*) index="" ;;
        esac
        ;;
      *'Type:'*)
        type="${line#*Type:}"
        type="${type#"${type%%[! ]*}"}"
        [ -n "${index:-}" ] && printf '%s\t%s\t%s\n' "${index}" "${name}" "${type}"
        index=""
        ;;
    esac
  done
}

# Number of devices seen by the server, empty when it does not answer.
device_count() {
  listing="$(devices)" || return 0
  printf '%s' "${listing}" | grep -c '' || true
}

# Components: devices grouped by name (RAM sticks share one, and the server
# may list a device twice after a new detection), in detection order, each
# included or excluded. Without a server it fails with no notification: the
# widget panel already says so.
components() {
  if ! listing="$(devices)"; then
    echo "rgb.sh: ${unreachable_message}" >&2
    exit 1
  fi
  printf '%s\n' "${listing}" | jq -R -s -c --argjson state "$(read_state)" '
    [split("\n")[] | select(length > 0) | split("\t") | {name: .[1], type: .[2]}]
    | reduce .[] as $device ([]; if any(.[]; .name == $device.name) then . else . + [$device] end)
    | map(. as $component | . + {enabled: (($state.off | index([$component.name])) == null)})'
}

# Waits until the server answers with a stable detection: the same non-zero
# device count on two polls in a row. Right after it starts, the server
# answers before it has detected anything: zero is only accepted at the end
# of the delay (a machine with no RGB device).
wait_for_server() {
  waited=0
  previous=""
  count=""
  while [ "${waited}" -lt "${restore_timeout}" ]; do
    count="$(device_count)"
    [ -n "${count}" ] && [ "${count}" != 0 ] && [ "${count}" = "${previous}" ] && return 0
    previous="${count}"
    sleep "${restore_poll_seconds}"
    waited=$((waited + restore_poll_seconds))
  done
  [ -n "${count}" ] && return 0
  fail "OpenRGB server not ready after ${restore_timeout} s"
}

# Sends $2 in Direct mode, which every device supports, to every device named
# in the JSON array $1: addressed by index, in a single call, so that devices
# sharing a name (RAM sticks) are all reached.
direct_color() {
  [ "$1" = "[]" ] && return 0
  listing="$(devices)" || fail "${unreachable_message}"
  names="$1"
  color="$2"
  set --
  for index in $(printf '%s\n' "${listing}" | jq -R -r --argjson names "${names}" \
    'split("\t") as $fields | select(($names | index([$fields[1]])) != null) | $fields[0]'); do
    set -- "$@" --device "${index}" --mode Direct --color "${color}"
  done
  [ $# -gt 0 ] && client "$@" >/dev/null
  return 0
}

apply() {
  read -r enabled color brightness mode <<EOF
$(read_state | jq -r '"\(.enabled) \(.color) \(.brightness) \(.mode)"')
EOF
  if [ "${enabled}" != "true" ]; then
    color="000000"
    mode="static"
  fi
  color="$(scale_color "${color}" "${brightness}")"
  # Effects ignore the color: their brightness goes through its own option.
  set -- --mode "$(openrgb_mode "${mode}")" --color "${color}"
  case "${mode}" in
    spectrum | rainbow) set -- "$@" --brightness "${brightness}" ;;
  esac
  output="$(client "$@")"
  # Devices without that mode (some coolers only have Direct) get the color
  # in Direct mode.
  refused="$(printf '%s\n' "${output}" | while IFS= read -r line; do
    case "${line}" in
      "Error: Mode '"*"' not available for device '"*"'")
        device="${line##*"for device '"}"
        printf '%s\n' "${device%\'}"
        ;;
    esac
  done | jq -R -s -c 'split("\n") | map(select(length > 0)) | unique')"
  direct_color "${refused}" "${color}"
  # Excluded components: black, over whatever they just received.
  [ "${enabled}" = "true" ] && direct_color "$(read_state | jq -c '.off')" 000000
  return 0
}

command="${1:-}"
[ $# -gt 0 ] && shift

case "${command}" in
  help | -h | --help) usage 0 ;;
  status)
    read_state
    exit 0
    ;;
  components)
    components
    exit 0
    ;;
esac

# One rgb.sh at a time: quick clicks in the widget and terminal commands write
# the state and apply it in order.
mkdir -p "${state_directory}"
exec 9>"${state_file}.lock"
flock 9

case "${command}" in
  on) write_state '.enabled = true' ;;
  off) write_state '.enabled = false' ;;
  toggle) write_state '.enabled = (.enabled | not)' ;;
  component)
    name="${1:-}"
    [ -n "${name}" ] || usage 2
    case "${2:-}" in
      on) write_state --arg name "${name}" '.off -= [$name]' ;;
      off) write_state --arg name "${name}" '.off = (.off + [$name] | unique)' ;;
      *) usage 2 ;;
    esac
    ;;
  color)
    value="${1:-}"
    value="$(printf '%s' "${value#\#}" | tr '[:lower:]' '[:upper:]')"
    is_hex_color "${value}" || usage 2
    write_state --arg color "${value}" '.enabled = true | .color = $color'
    ;;
  brightness)
    is_percent "${1:-}" || usage 2
    write_state --argjson brightness "$1" '.enabled = true | .brightness = $brightness'
    ;;
  mode)
    openrgb_mode "${1:-}" >/dev/null || usage 2
    write_state --arg mode "$1" '.enabled = true | .mode = $mode'
    ;;
  restore) wait_for_server ;;
  *) usage 2 ;;
esac

apply
