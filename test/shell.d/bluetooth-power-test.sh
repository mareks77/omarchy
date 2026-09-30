#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
export HOME="$tmp/home" XDG_STATE_HOME="$tmp/state with spaces" MOCK_DIR="$tmp"
export PATH="$tmp/bin:$ROOT/bin:$PATH" OMARCHY_PATH="$ROOT" OMARCHY_BLUETOOTH_POWER_WAIT_SECONDS=0
export OMARCHY_BLUETOOTH_MIGRATION_MARKER="$tmp/migrated"
state_file="$XDG_STATE_HOME/omarchy/bluetooth-power"

cat >"$tmp/bin/busctl" <<'SH'
#!/bin/bash
while [[ $1 == --* ]]; do shift; done
printf 'busctl %s\n' "$*" >>"$MOCK_DIR/log"
[[ -n ${MOCK_BUS_DOWN:-} ]] && exit 1
case "$1" in
  tree)
    [[ -n ${MOCK_NO_ADAPTERS:-} ]] && exit 0
    printf '/org/bluez/hci0\n/org/bluez/hci0/dev_AA_BB\n'
    [[ -f $MOCK_DIR/hci1 ]] && echo /org/bluez/hci1
    ;;
  get-property)
    [[ -n ${MOCK_READ_FAIL:-} ]] && exit 1
    printf 'b %s\n' "$(cat "$MOCK_DIR/${3##*/}")"
    ;;
  set-property)
    [[ -n ${MOCK_SET_FAIL:-} ]] && exit 1
    if [[ -f $MOCK_DIR/reject-once ]]; then
      rm "$MOCK_DIR/reject-once"
      exit 1
    fi
    [[ $7 == true && $(cat "$MOCK_DIR/block") != none ]] && exit 1
    echo "$7" >"$MOCK_DIR/${3##*/}"
    ;;
esac
exit 0
SH

cat >"$tmp/bin/rfkill" <<'SH'
#!/bin/bash
printf 'rfkill %s\n' "$*" >>"$MOCK_DIR/log"
if [[ $1 == unblock ]]; then
  [[ -n ${MOCK_UNBLOCK_FAIL:-} ]] && exit 1
  [[ $(cat "$MOCK_DIR/block") == soft ]] && echo none >"$MOCK_DIR/block"
elif [[ $1 == --raw ]]; then
  if [[ $(cat "$MOCK_DIR/block") == soft ]]; then echo blocked; else echo unblocked; fi
else
  echo "unexpected rfkill operation" >&2
  exit 1
fi
exit 0
SH

cat >"$tmp/bin/bluetoothctl" <<'SH'
#!/bin/bash
printf 'bluetoothctl %s\n' "$*" >>"$MOCK_DIR/log"
if [[ $1 == show ]]; then
  if [[ $(cat "$MOCK_DIR/hci0") == true ]]; then echo 'Powered: yes'; else echo 'Powered: no'; fi
fi
SH

cat >"$tmp/bin/systemctl" <<'SH'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$MOCK_DIR/log"
[[ -n ${MOCK_NO_SESSION:-} && $1 == --user ]] && exit 1
exit 0
SH

cat >"$tmp/bin/sudo" <<'SH'
#!/bin/bash
[[ $* == 'rfkill unblock bluetooth' || $* == "install -Dm644 /dev/null $MOCK_DIR/migrated" ]] || exit 1
"$@"
SH
chmod +x "$tmp/bin/"*

reset_radio() {
  echo "$1" >"$tmp/hci0"
  echo none >"$tmp/block"
  rm -f "$tmp/hci1" "$tmp/reject-once" "$tmp/migrated" "$state_file"
  : >"$tmp/log"
}

assert_saved() {
  [[ $(cat "$state_file") == "$1" ]] || fail "saved Bluetooth preference is $1"
}

reset_radio true
omarchy-bluetooth-power off
[[ $(cat "$tmp/hci0") == false && $(cat "$tmp/block") == none ]] || fail "normal off only powers down BlueZ"
! grep -q '^rfkill ' "$tmp/log" || fail "normal off touches rfkill"
assert_saved off
# The exact operation Chromium uses must now work, without an unblock.
busctl --system set-property org.bluez /org/bluez/hci0 org.bluez.Adapter1 Powered b true
[[ $(cat "$tmp/hci0") == true ]] || fail "a BlueZ client can power on after Omarchy turns off"
pass "normal off leaves Chromium's BlueZ power-on path usable"

omarchy-bluetooth-power save
assert_saved on
pass "logout snapshots power changes made by another client"

reset_radio false
echo soft >"$tmp/block"
omarchy-bluetooth-power on
[[ $(cat "$tmp/hci0") == true && $(cat "$tmp/block") == none ]] || fail "explicit on clears a software block"
assert_saved on
pass "explicit on recovers a software block and records success"

omarchy-bluetooth-power toggle
assert_saved off
omarchy-bluetooth-power toggle
assert_saved on
omarchy-bluetooth-power is-on || fail "is-on detects powered adapter"
omarchy-bluetooth-power off
if omarchy-bluetooth-power is-on; then fail "is-on detects unpowered adapter"; fi
pass "toggle and is-on follow BlueZ Powered"

reset_radio false
echo true >"$tmp/hci1"
omarchy-bluetooth-power is-on || fail "secondary adapter counts as on"
omarchy-bluetooth-power toggle
[[ $(cat "$tmp/hci0") == false && $(cat "$tmp/hci1") == false ]] || fail "off reaches all controllers"
omarchy-bluetooth-power on
[[ $(cat "$tmp/hci0") == true && $(cat "$tmp/hci1") == true ]] || fail "on reaches all controllers"
! grep -q 'set-property.*dev_AA_BB' "$tmp/log" || fail "device mistaken for adapter"
pass "both directions reach every controller, not device paths"

reset_radio true
omarchy-bluetooth-power off
echo true >"$tmp/hci0" # BlueZ AutoEnable on the next boot.
omarchy-bluetooth-power restore
[[ $(cat "$tmp/hci0") == false ]] || fail "login restores the saved off state"
assert_saved off
pass "saved off survives a new BlueZ session"

# Restoring is not explicit consent to lift an airplane-mode block.
omarchy-bluetooth-power on
echo false >"$tmp/hci0"
echo soft >"$tmp/block"
: >"$tmp/log"
if omarchy-bluetooth-power restore 2>/dev/null; then fail "restore unexpectedly bypasses soft block"; fi
! grep -q '^rfkill ' "$tmp/log" || fail "restore clears an external rfkill block"
assert_saved on
pass "login respects an external software block without losing the preference"

reset_radio false
omarchy-bluetooth-power save
for failure in MOCK_SET_FAIL MOCK_UNBLOCK_FAIL; do
  if env "$failure=1" omarchy-bluetooth-power on 2>/dev/null; then fail "$failure is reported"; fi
  assert_saved off
done
echo hard >"$tmp/block"
if omarchy-bluetooth-power on 2>/dev/null; then fail "hard block is reported"; fi
assert_saved off
pass "failed power changes and hard blocks do not overwrite the preference"

reset_radio false
omarchy-bluetooth-power on
for failure in MOCK_BUS_DOWN MOCK_NO_ADAPTERS MOCK_READ_FAIL; do
  env "$failure=1" omarchy-bluetooth-power save
  env "$failure=1" omarchy-bluetooth-power restore
  assert_saved on
done
pass "missing hardware and D-Bus failures never become a saved off preference"

reset_radio false
omarchy-bluetooth-power restore
! grep -q 'set-property' "$tmp/log" || fail "missing state causes a power change"
mkdir -p "$(dirname "$state_file")"
echo invalid >"$state_file"
if omarchy-bluetooth-power restore 2>/dev/null; then fail "invalid state is rejected"; fi
! grep -q 'set-property' "$tmp/log" || fail "invalid state causes a power change"
pass "absent or invalid state is never executed as a power direction"

reset_radio false
touch "$tmp/reject-once"
OMARCHY_BLUETOOTH_POWER_WAIT_SECONDS=2 omarchy-bluetooth-power on
assert_saved on
pass "power control retries a transient BlueZ transition"

reset_radio true
omarchy-bluetooth-device connect AA:BB:CC:DD:EE:FF
! grep -q '^rfkill ' "$tmp/log" || fail "already powered connect incurs a power change"
grep -qx 'bluetoothctl connect AA:BB:CC:DD:EE:FF' "$tmp/log" || fail "already powered connect reaches bluetoothctl"
reset_radio false
omarchy-bluetooth-device connect AA:BB:CC:DD:EE:FF
assert_saved on
grep -qx 'bluetoothctl connect AA:BB:CC:DD:EE:FF' "$tmp/log" || fail "unpowered connect reaches bluetoothctl"
pass "connecting reuses power control only when needed"

reset_radio false
echo soft >"$tmp/block"
bash -euo pipefail "$ROOT/migrations/1790703856.sh"
assert_saved off
[[ $(cat "$tmp/block") == none && $(cat "$tmp/hci0") == false ]] || fail "migration preserves off without its old block"
echo true >"$tmp/hci0" # An interrupted unblock triggered AutoEnable.
bash -euo pipefail "$ROOT/migrations/1790703856.sh"
assert_saved off
[[ $(cat "$tmp/hci0") == false ]] || fail "migration retry recaptures a temporary on state"
pass "migration clears the old block, preserves off and is retry-safe"
echo soft >"$tmp/block"
bash -euo pipefail "$ROOT/migrations/1790703856.sh"
[[ $(cat "$tmp/block") == soft ]] || fail "second account's migration clears a new external block"
pass "machine marker protects an external block on subsequent migrations"

reset_radio true
MOCK_NO_SESSION=1 bash -euo pipefail "$ROOT/migrations/1790703856.sh"
assert_saved on
[[ -L $HOME/.config/systemd/user/graphical-session.target.wants/omarchy-bluetooth-power.service ]] || fail "migration without a user manager enables next login"
pass "migration preserves on and enables restoration without a user manager"

reset_radio false
echo soft >"$tmp/block"
MOCK_BUS_DOWN=1 bash -euo pipefail "$ROOT/migrations/1790703856.sh"
assert_saved off
[[ $(cat "$tmp/block") == none ]] || fail "offline migration leaves the legacy block"
pass "migration preserves a blocked off preference even without BlueZ"

unit="$ROOT/default/systemd/user/omarchy-bluetooth-power.service"
for line in 'ExecStart=/usr/bin/omarchy-bluetooth-power restore' 'ExecStop=/usr/bin/omarchy-bluetooth-power save' 'PartOf=graphical-session.target' 'After=graphical-session.target' 'RemainAfterExit=yes' 'WantedBy=graphical-session.target'; do
  grep -qxF "$line" "$unit" || fail "Bluetooth state unit is missing $line"
done
grep -qF 'omarchy-bluetooth-power.service' "$ROOT/install/user/first-run/enable-user-units.sh" || fail "first run enables Bluetooth state unit"
pass "graphical session restores on login and saves on logout for new installs"
