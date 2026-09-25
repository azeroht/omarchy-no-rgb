#!/usr/bin/env bash
# Tests for rgb.sh. openrgb and notify-send are replaced by stubs that record
# their arguments, so the tests run anywhere: no OpenRGB server, no RGB
# device, and no real light ever changes.
#
# Usage: tests/rgb.test.sh   (or "make test")

set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rgb.sh"
STUBS="$(mktemp -d)"
trap 'rm -rf "$STUBS"' EXIT
PARALLEL_CALLS=8
failures=0

# openrgb stub: records every call, lists four devices (two RAM sticks and
# two coolers sharing a name), refuses any mode but Direct for the coolers
# like the real one does (one error line per device), lists nothing with NO_DEVICES, nothing on the first EMPTY_POLLS
# polls, fails the listing with LIST_FAILS, and hangs with NO_SERVER.
cat >"$STUBS/openrgb" <<'EOF'
#!/bin/sh
directory="$(dirname "$0")"
[ -n "${NO_SERVER:-}" ] && exec sleep 5
case "$*" in
  *--list-devices*)
    [ -z "${LIST_FAILS:-}" ] || exit 1
    polls=$(($(cat "$directory/polls" 2>/dev/null || echo 0) + 1))
    echo "$polls" >"$directory/polls"
    [ -n "${NO_DEVICES:-}" ] && exit 0
    [ "$polls" -le "${EMPTY_POLLS:-0}" ] && exit 0
    printf '0: ENE DRAM\n  Type:           DRAM\n  Modes: Static\n1: Commander Core\n  Type:           Cooler\n2: ENE DRAM\n  Type:           DRAM\n3: Commander Core\n  Type:           Cooler\n'
    exit 0
    ;;
esac
printf '%s\n' "$*" >>"$directory/calls.log"
case "$*" in
  *--device*) ;;
  *"--mode Direct"*) ;;
  *--mode*) printf "Error: Mode 'X' not available for device 'Commander Core'\n%.0s" 1 2 ;;
esac
EOF
printf '#!/bin/sh\necho "$*" >>"$(dirname "$0")/notifications.log"\n' >"$STUBS/notify-send"
chmod +x "$STUBS/openrgb" "$STUBS/notify-send"
export PATH="$STUBS:$PATH" XDG_STATE_HOME="$STUBS/state" NO_RGB_RESTORE_POLL_SECONDS=0
STATE="$STUBS/state/azeroht-no-rgb.json"
mkdir -p "$STUBS/state"

expect() {
  local label="$1" actual="$2" wanted="$3"
  if [ "$actual" = "$wanted" ]; then
    printf '  ok    %-50s [%s]\n' "$label" "$actual"
  else
    printf '  FAIL  %-50s [%s], wanted [%s]\n' "$label" "$actual" "$wanted"
    failures=$((failures + 1))
  fi
}

# openrgb calls since the previous one, without the server address,
# joined by " | ".
calls() {
  [ -f "$STUBS/calls.log" ] || return 0
  sed 's/^--client [^ ]* //' "$STUBS/calls.log" | paste -sd '|' | sed 's/|/ | /g'
  rm -f "$STUBS/calls.log"
}

# Expected calls for some OpenRGB options and a color, with the Direct
# fallback of both coolers, by index, in a single call.
applied() {
  printf '%s | --device 1 --mode Direct --color %s --device 3 --mode Direct --color %s' "$1" "$2" "$2"
}

state() {
  "$SCRIPT" status | jq -r "$1"
}

reset_state() {
  rm -f "$STATE" "$STUBS/calls.log" "$STUBS/notifications.log" "$STUBS/polls"
}

echo "rgb.sh state"
expect "default: off" "$(state .enabled)" "false"
expect "status: never calls openrgb" "$(calls)" ""
"$SCRIPT" color '#ff00aa'
expect "color: turns on and saves" "$(state '[.enabled, .color] | join(" ")')" "true FF00AA"
expect "color: sent as static" "$(calls)" "$(applied '--mode Static --color FF00AA' FF00AA)"
"$SCRIPT" brightness 50
expect "brightness 50 %: dimmed color" "$(calls)" "$(applied '--mode Static --color 7F0055' 7F0055)"
"$SCRIPT" brightness 100
"$SCRIPT" mode rainbow
calls >/dev/null
"$SCRIPT" off
expect "off: static black" "$(calls)" "$(applied '--mode Static --color 000000' 000000)"
"$SCRIPT" toggle
expect "toggle: settings kept" "$(calls)" "$(applied '--mode Rainbow --color FF00AA --brightness 100' FF00AA)"
"$SCRIPT" toggle
expect "toggle: on -> off" "$(state .enabled)" "false"
"$SCRIPT" on
calls >/dev/null
"$SCRIPT" restore
expect "restore: reapplies the state" "$(calls)" "$(applied '--mode Rainbow --color FF00AA --brightness 100' FF00AA)"

echo "rgb.sh effects"
for pair in "static:Static" "breathing:Breathing" "spectrum:Spectrum Cycle" "rainbow:Rainbow"; do
  "$SCRIPT" mode "${pair%%:*}"
  first_call="$(calls | cut -d'|' -f1)"
  first_call="${first_call#--mode }"
  expect "mode ${pair%%:*}: ${pair#*:}" "${first_call%% --color*}" "${pair#*:}"
done

echo "rgb.sh components"
reset_state
expect "grouped by name, with their type" "$("$SCRIPT" components)" \
  '[{"name":"ENE DRAM","type":"DRAM","enabled":true},{"name":"Commander Core","type":"Cooler","enabled":true}]'
"$SCRIPT" on
calls >/dev/null
"$SCRIPT" component "ENE DRAM" off
expect "excluded: black in Direct on all its indexes" "$(calls | awk -F' [|] ' '{print $NF}')" \
  "--device 0 --mode Direct --color 000000 --device 2 --mode Direct --color 000000"
expect "excluded: saved" "$(state '.off | join(",")')" "ENE DRAM"
expect "excluded: flagged in the list" "$("$SCRIPT" components | jq -c 'map(.enabled)')" "[false,true]"
"$SCRIPT" component "ENE DRAM" off
expect "excluded twice: a single entry" "$(state '.off | length')" "1"
calls >/dev/null
"$SCRIPT" off
expect "off: no targeted call" "$(calls | grep -c -- '--device 0')" "0"
"$SCRIPT" component "ENE DRAM" on
expect "included again: removed from the list" "$(state '.off | length')" "0"
reset_state
"$SCRIPT" component "Ghost" off
calls >/dev/null
"$SCRIPT" on
expect "excluded but undetected: nothing darkened" "$(calls | grep -c -- '--color 000000')" "0"

echo "rgb.sh toggle with no state"
reset_state
"$SCRIPT" toggle
expect "default off -> on" "$(state .enabled)" "true"

echo "rgb.sh concurrent calls"
reset_state
pids=()
for index in $(seq 1 "$PARALLEL_CALLS"); do
  "$SCRIPT" brightness "${index}0" &
  pids+=("$!")
done
parallel_failures=0
for pid in "${pids[@]}"; do
  wait "$pid" || parallel_failures=$((parallel_failures + 1))
done
expect "$PARALLEL_CALLS calls: no failure" "$parallel_failures" "0"
expect "state still valid" "$(jq -r 'type' "$STATE")" "object"
expect "no temporary file left" "$(find "$STUBS/state" -name 'azeroht-no-rgb.json.*' ! -name '*.lock' | wc -l)" "0"

echo "rgb.sh without a server"
reset_state
NO_SERVER=1 NO_RGB_CLIENT_TIMEOUT=1 "$SCRIPT" on 2>/dev/null
expect "command: fails" "$?" "1"
expect "command: notifies" "$(grep -c 'unreachable' "$STUBS/notifications.log")" "1"
rm -f "$STUBS/notifications.log"
NO_SERVER=1 NO_RGB_CLIENT_TIMEOUT=1 "$SCRIPT" components 2>/dev/null
expect "components: fails" "$?" "1"
expect "components: no notification" "$([ -f "$STUBS/notifications.log" ] && echo notified)" ""
"$SCRIPT" component "ENE DRAM" off
LIST_FAILS=1 "$SCRIPT" on 2>/dev/null
expect "listing fails while darkening: fails" "$?" "1"
NO_SERVER=1 NO_RGB_CLIENT_TIMEOUT=1 NO_RGB_RESTORE_TIMEOUT=1 NO_RGB_RESTORE_POLL_SECONDS=1 "$SCRIPT" restore 2>/dev/null
expect "restore: gives up after the delay" "$?" "1"
NO_DEVICES=1 NO_RGB_RESTORE_TIMEOUT=1 NO_RGB_RESTORE_POLL_SECONDS=1 "$SCRIPT" restore 2>/dev/null
expect "restore: no RGB device, no failure" "$?" "0"
reset_state
EMPTY_POLLS=2 "$SCRIPT" restore 2>/dev/null
# 4 polls until the detection is stable, then 1 listing for the Direct fallback.
expect "restore: waits for the end of the detection" "$(cat "$STUBS/polls")" "5"

echo "rgb.sh input"
reset_state
"$SCRIPT" color 00ff00
"$SCRIPT" brightness 50
"$SCRIPT" mode rainbow
for arguments in "color 12345" "color GGGGGG" "color ##00FF00" "color" "brightness 101" "brightness -1" \
  "brightness" "mode disco" "mode" "component" "component ENE" "component ENE maybe" "unknown" ""; do
  # shellcheck disable=SC2086
  "$SCRIPT" $arguments 2>/dev/null
  expect "rgb.sh ${arguments:-with no argument}: exit code 2" "$?" "2"
done
expect "state unchanged after refusals" "$(state '[.color, .brightness, .mode] | join(" ")')" "00FF00 50 rainbow"
"$SCRIPT" help 2>/dev/null
expect "help: exit code 0" "$?" "0"
expect "help: lists the commands" "$("$SCRIPT" help 2>&1 | grep -c '^  rgb.sh ')" "9"

echo "rgb.sh state file"
printf 'not json' >"$STATE"
expect "unreadable: defaults" "$(state .color)" "FF6600"
printf '[]' >"$STATE"
expect "array: defaults" "$(state .mode)" "static"
printf '{"color":"00FF00"}' >"$STATE"
expect "partial: completed" "$(state '[.enabled, .color, .brightness] | join(" ")')" "false 00FF00 100"
printf '{"enabled":"yes","color":"zz","brightness":55.5,"mode":"disco","off":["GPU",3,"GPU"]}' >"$STATE"
expect "edited by hand: sanitized" "$(state '[.enabled, .color, .brightness, .mode, (.off | join(","))] | join(" ")')" \
  "false FF6600 55 static GPU"

echo
if [ "$failures" -eq 0 ]; then
  echo "rgb.sh: all tests pass"
else
  echo "rgb.sh: $failures failure(s)"
  exit 1
fi
