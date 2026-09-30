echo "Remember Bluetooth power without blocking application power-on"

state_file="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/bluetooth-power"

# Old Omarchy off and an external airplane-mode block are indistinguishable.
# Preserve every existing block; only an explicit Omarchy on may clear it.
# Capture off through the helper's atomic write even if BlueZ is unavailable.
if [[ ! -e $state_file ]]; then
  if rfkill --raw --noheadings --output SOFT list bluetooth | grep -qx blocked; then
    omarchy-bluetooth-power save off
    echo "Existing Bluetooth blocks are preserved. Enable Bluetooth once in Omarchy to allow application power-on."
  else
    omarchy-bluetooth-power save
  fi
fi

# Enable for the next graphical login without starting or restarting a monitor
# in the current session: its saved state may predate an application's power-on.
# A running monitor continues unchanged. No user manager means writing the
# wants symlink for next login instead.
if ! systemctl --user daemon-reload || ! systemctl --user enable omarchy-bluetooth-power.service; then
  wants_dir="$HOME/.config/systemd/user/graphical-session.target.wants"
  mkdir -p "$wants_dir"
  ln -sfn /usr/lib/systemd/user/omarchy-bluetooth-power.service "$wants_dir/omarchy-bluetooth-power.service"
fi
