echo "Let applications turn Bluetooth on after Omarchy turns it off"

state_file="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/bluetooth-power"
marker="${OMARCHY_BLUETOOTH_MIGRATION_MARKER:-/var/lib/omarchy/migrations/1790703856}"

# Record the old Powered state before removing the block. Keep this file on a
# retry: unblocking can trigger AutoEnable, which is not a new user preference.
# A software block is also an off preference when bluetoothd is stopped.
soft_blocked=false
if rfkill --raw --noheadings --output SOFT list bluetooth | grep -qx blocked; then
  soft_blocked=true
fi
if [[ ! -e $state_file ]]; then
  if [[ $soft_blocked == "true" ]]; then
    mkdir -p "$(dirname "$state_file")"
    printf 'off\n' >"$state_file"
  else
    omarchy-bluetooth-power save
  fi
fi

# The old helper used this block for normal off. Clear Bluetooth only (never
# Wi-Fi or hardware blocks), once per machine: a second user's migration must
# not clear a new airplane-mode block. sudo also covers updates outside a seat.
if [[ ! -e $marker && $soft_blocked == "true" ]]; then
  sudo rfkill unblock bluetooth
  soft_blocked=false
fi

# Restore immediately when BlueZ is reachable, including an update over SSH.
# No hardware/daemon means no preference was captured; defer to the next login.
if [[ -f $state_file && ( ! -e $marker || $soft_blocked == "false" ) ]] && systemctl is-active --quiet bluetooth.service; then
  omarchy-bluetooth-power restore
fi

# Record machine-wide repair only after restoring succeeds, so an interruption
# is retried without recapturing the temporary AutoEnable state.
if [[ ! -e $marker ]]; then
  sudo install -Dm644 /dev/null "$marker"
fi

# Fixed package paths supply the unit. With no live user manager, enable it for
# the next session without swallowing a repair failure in the steps above.
if systemctl --user daemon-reload && systemctl --user enable omarchy-bluetooth-power.service; then
  if [[ $soft_blocked == "false" ]] && systemctl --user is-active --quiet graphical-session.target; then
    systemctl --user start omarchy-bluetooth-power.service
  fi
else
  wants_dir="$HOME/.config/systemd/user/graphical-session.target.wants"
  mkdir -p "$wants_dir"
  ln -sfn /usr/lib/systemd/user/omarchy-bluetooth-power.service "$wants_dir/omarchy-bluetooth-power.service"
fi
