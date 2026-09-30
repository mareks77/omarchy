echo "Remember Bluetooth power without blocking application power-on"

state_file="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/bluetooth-power"

# Old Omarchy off and an external airplane-mode block are indistinguishable.
# Preserve every existing block; only an explicit Omarchy on may clear it.
# Capture off through the helper's atomic write even if BlueZ is unavailable.
if [[ ! -e $state_file ]]; then
  if rfkill --raw --noheadings --output SOFT list bluetooth | grep -qx blocked; then
    omarchy-bluetooth-power save off
  else
    omarchy-bluetooth-power save
  fi
fi

# Fixed package paths supply the unit. With no live user manager, enable it for
# the next session. Starting is asynchronous: BlueZ may become available later.
if systemctl --user daemon-reload && systemctl --user enable omarchy-bluetooth-power.service; then
  if systemctl --user is-active --quiet graphical-session.target; then
    systemctl --user restart --no-block omarchy-bluetooth-power.service
  fi
else
  wants_dir="$HOME/.config/systemd/user/graphical-session.target.wants"
  mkdir -p "$wants_dir"
  ln -sfn /usr/lib/systemd/user/omarchy-bluetooth-power.service "$wants_dir/omarchy-bluetooth-power.service"
fi
