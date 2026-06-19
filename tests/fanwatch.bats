#!/usr/bin/env bats
# Unit tests for fanwatch's pure logic. The script returns early when sourced
# (the guard sits just above the trap/header section), so each test sources it
# fresh — bats isolates tests in subshells — and calls its functions directly.

setup() {
  FW="$BATS_TEST_DIRNAME/../fanwatch"
}

# A thinkfan.yaml whose lowest non-zero level starts at 60 °C.
write_thinkfan_config() {
  cat >"$BATS_TEST_TMPDIR/thinkfan.yaml" <<'EOF'
levels:
  - [0, 0, 55]
  - [2, 60, 75]
  - [4, 72, 88]
  - ["level full-speed", 85, 32767]
EOF
}

# A synthetic hwmon tree: acpitz (low priority), coretemp with a labelled
# package sensor, and an amdgpu device carrying the GPU temp, two fans and a PWM.
# Echoes the tree root. amdgpu is used for the GPU so detection never falls back
# to nvidia-smi, keeping the result independent of the host.
make_hwmon() {
  local root="$BATS_TEST_TMPDIR/hwmon"
  rm -rf "$root"; mkdir -p "$root"/hwmon0 "$root"/hwmon1 "$root"/hwmon2
  printf 'acpitz\n' >"$root/hwmon0/name";   printf '70000\n' >"$root/hwmon0/temp1_input"
  printf 'coretemp\n' >"$root/hwmon1/name"
  printf 'Package id 0\n' >"$root/hwmon1/temp1_label"; printf '66000\n' >"$root/hwmon1/temp1_input"
  printf 'Core 0\n'       >"$root/hwmon1/temp2_label"; printf '60000\n' >"$root/hwmon1/temp2_input"
  printf 'amdgpu\n' >"$root/hwmon2/name"
  printf 'edge\n'   >"$root/hwmon2/temp1_label"; printf '58000\n' >"$root/hwmon2/temp1_input"
  printf '1500\n'   >"$root/hwmon2/fan1_input"
  printf '2000\n'   >"$root/hwmon2/fan2_input"
  printf '64\n'     >"$root/hwmon2/pwm1"
  printf '%s' "$root"
}

# --- detect_backend: explicit override wins ----------------------------------

@test "detect_backend honours FANWATCH_BACKEND" {
  source "$FW"
  FANWATCH_BACKEND=hwmon run detect_backend
  [ "$output" = "hwmon" ]
}

# --- read_mC: millidegrees -> rounded whole °C -------------------------------

@test "read_mC rounds millidegrees to whole degrees" {
  source "$FW"
  printf '66000\n' >"$BATS_TEST_TMPDIR/t"; run read_mC "$BATS_TEST_TMPDIR/t"; [ "$output" = "66" ]
  printf '66700\n' >"$BATS_TEST_TMPDIR/t"; run read_mC "$BATS_TEST_TMPDIR/t"; [ "$output" = "67" ]
}

@test "read_mC fails on a missing or non-numeric input" {
  source "$FW"
  run read_mC "$BATS_TEST_TMPDIR/nope"; [ "$status" -ne 0 ]
  printf 'N/A\n' >"$BATS_TEST_TMPDIR/t"; run read_mC "$BATS_TEST_TMPDIR/t"; [ "$status" -ne 0 ]
}

# --- hwmon_temp_by_label: pick the input matching a label --------------------

@test "hwmon_temp_by_label resolves the input behind a matching label" {
  source "$FW"; root=$(make_hwmon)
  run hwmon_temp_by_label "$root/hwmon1" 'Core 0'
  [ "$output" = "$root/hwmon1/temp2_input" ]
}

@test "hwmon_temp_by_label falls back to temp1_input when no label matches" {
  source "$FW"; root=$(make_hwmon)
  run hwmon_temp_by_label "$root/hwmon1" 'no such label'
  [ "$output" = "$root/hwmon1/temp1_input" ]
}

# --- discover_hwmon + sample_hwmon: end to end on the synthetic tree ---------

@test "discover_hwmon prefers coretemp over acpitz and finds fans/pwm/gpu" {
  source "$FW"; root=$(make_hwmon)
  discover_hwmon "$root"
  [ "$HW_CPU_NAME" = "coretemp" ]
  [ "$HW_CPU" = "$root/hwmon1/temp1_input" ]
  [ "$HW_GPU" = "$root/hwmon2/temp1_input" ]
  [ "$HW_GPU_NAME" = "amdgpu" ]
  [ "${#HW_FANS[@]}" -eq 2 ]
  [ "$HW_PWM" = "$root/hwmon2/pwm1" ]
}

@test "sample_hwmon reports temps, joined RPMs and PWM as a percentage" {
  source "$FW"; root=$(make_hwmon)
  discover_hwmon "$root"
  sample_hwmon
  [ "$cpu" = "66" ]
  [ "$gpu" = "58" ]
  [ "$rpm" = "2000" ]            # primary RPM is the fastest fan
  [ "$rpmdisp" = "1500/2000" ]   # both fans shown, slash-joined
  [ "$leveltext" = "25%" ]       # 64/255 ~= 25%
  [ "$fanoff" -eq 0 ]
}

@test "sample_hwmon flags the fan as off when PWM and RPM are zero" {
  source "$FW"; root=$(make_hwmon)
  printf '0\n' >"$root/hwmon2/pwm1"
  printf '0\n' >"$root/hwmon2/fan1_input"; printf '0\n' >"$root/hwmon2/fan2_input"
  discover_hwmon "$root"
  sample_hwmon
  [ "$fanoff" -eq 1 ]
  [ "$leveltext" = "0%" ]
}

# Fake macOS sensor helpers on a temp dir, returned for prepending to PATH.
# smctemp covers cpu/gpu/fan (fan output carries an index to exercise parsing);
# istats covers cpu temp + fan only.
make_mac_tools() {
  local dir="$BATS_TEST_TMPDIR/macbin"; mkdir -p "$dir"
  cat >"$dir/smctemp" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -c) echo "61.8" ;;
  -g) echo "47.2°C" ;;
  -f) printf 'Fan 0: 2345 rpm\nFan 1: 3010 rpm\n' ;;
esac
EOF
  cat >"$dir/istats" <<'EOF'
#!/usr/bin/env bash
[[ $1 == cpu ]] && echo "55.0"
[[ $1 == fan ]] && echo "1800"
EOF
  chmod +x "$dir/smctemp" "$dir/istats"
  printf '%s' "$dir"
}

# --- macOS backend (mocked SMC helpers) --------------------------------------

@test "mac_round rounds the first number, or the largest with max" {
  source "$FW"
  [ "$(printf 'Fan 0: 2345 rpm\n' | mac_round)" = "0" ]      # first number is the index
  [ "$(printf 'Fan 0: 2345 rpm\n' | mac_round max)" = "2345" ]
  [ "$(printf '61.8°C\n' | mac_round)" = "62" ]
}

@test "discover_macos prefers smctemp and enables gpu+fan" {
  source "$FW"; PATH="$(make_mac_tools):$PATH"
  discover_macos
  [ "$MAC_TEMP_TOOL" = "smctemp" ]
  [ "$MAC_FAN_TOOL" = "smctemp" ]
  [ "$MAC_GPU" -eq 1 ]
}

@test "FANWATCH_MAC_TOOL forces the helper" {
  source "$FW"; PATH="$(make_mac_tools):$PATH"
  FANWATCH_MAC_TOOL=istats discover_macos
  [ "$MAC_TEMP_TOOL" = "istats" ]
  [ "$MAC_GPU" -eq 0 ]
}

# Auto-detection must skip powermetrics on Apple Silicon (its smc sampler has no
# "CPU die temperature" line there), so a machine with only powermetrics ends up
# with no tool and triggers the install-hints error rather than a blank loop.
# These run on the Linux CI box too, so nothing here may depend on a real macOS:
# `uname` is overridden as a shell function to force arm64 regardless of host,
# and PATH is set to a dir holding only a powermetrics stub so command -v finds
# powermetrics but no other helper. The stub is never executed (discover only
# probes for it with command -v), so an empty executable file suffices.
@test "discover_macos skips powermetrics on Apple Silicon" {
  source "$FW"
  uname() { echo arm64; }                 # force arch independently of the host
  dir="$BATS_TEST_TMPDIR/arm"; mkdir -p "$dir"
  : >"$dir/powermetrics"; chmod +x "$dir/powermetrics"
  PATH="$dir" discover_macos
  [ -z "$MAC_TEMP_TOOL" ]
}

# But an explicit FANWATCH_MAC_TOOL=powermetrics is still honoured on arm64;
# the skip is only about the auto-pick, not a hard block.
@test "discover_macos honours an explicit powermetrics pick on Apple Silicon" {
  source "$FW"
  uname() { echo arm64; }
  dir="$BATS_TEST_TMPDIR/arm2"; mkdir -p "$dir"
  : >"$dir/powermetrics"; chmod +x "$dir/powermetrics"
  PATH="$dir" FANWATCH_MAC_TOOL=powermetrics discover_macos
  [ "$MAC_TEMP_TOOL" = "powermetrics" ]
}

@test "sample_macos parses smctemp temps and the fastest fan" {
  source "$FW"; PATH="$(make_mac_tools):$PATH"; discover_macos
  sample_macos
  [ "$cpu" = "62" ]
  [ "$gpu" = "47" ]
  [ "$rpm" = "3010" ]       # the faster of the two fans
  [ "$leveltext" = "on" ]
  [ "$fanoff" -eq 0 ]
}

@test "sample_macos via istats has cpu and fan but no gpu" {
  source "$FW"; PATH="$(make_mac_tools):$PATH"
  FANWATCH_MAC_TOOL=istats discover_macos
  sample_macos
  [ "$cpu" = "55" ]
  [ -z "$gpu" ]
  [ "$rpm" = "1800" ]
}

@test "sample_macos flags the fan as off at zero rpm" {
  source "$FW"
  dir="$BATS_TEST_TMPDIR/macoff"; mkdir -p "$dir"
  printf '#!/usr/bin/env bash\ncase "$1" in -c) echo 40 ;; -f) echo 0 ;; esac\n' >"$dir/smctemp"
  chmod +x "$dir/smctemp"; PATH="$dir:$PATH"; discover_macos
  sample_macos
  [ "$fanoff" -eq 1 ]
  [ "$leveltext" = "off" ]
}

# --- parse_off_below: derive the fan-off threshold from thinkfan.yaml --------

@test "parse_off_below takes the lowest non-zero level's lower bound" {
  write_thinkfan_config
  source "$FW"
  run parse_off_below "$BATS_TEST_TMPDIR/thinkfan.yaml"
  [ "$output" = "60" ]
}

@test "parse_off_below falls back to 58 when the file is missing" {
  source "$FW"
  run parse_off_below "$BATS_TEST_TMPDIR/does-not-exist.yaml"
  [ "$output" = "58" ]
}

@test "parse_off_below falls back to 58 when no levels parse" {
  printf 'levels: []\n' >"$BATS_TEST_TMPDIR/empty.yaml"
  source "$FW"
  run parse_off_below "$BATS_TEST_TMPDIR/empty.yaml"
  [ "$output" = "58" ]
}

# --- arrow: trend glyph vs the previous sample -------------------------------
# Colours are empty without a TTY, so the output is the bare glyph.

@test "arrow shows a rising glyph when current exceeds previous" {
  source "$FW"
  run arrow 70 60
  [ "$output" = "▲" ]
}

@test "arrow shows a falling glyph when current is below previous" {
  source "$FW"
  run arrow 60 70
  [ "$output" = "▼" ]
}

@test "arrow shows a steady glyph when current equals previous" {
  source "$FW"
  run arrow 65 65
  [ "$output" = "—" ]
}

@test "arrow is a blank space when there is no previous sample" {
  source "$FW"
  run arrow 65 ""
  [ "$output" = " " ]   # a single space placeholder keeps columns aligned
}

# --- sparkline: map the CPU history array to block glyphs --------------------

@test "sparkline maps the scale endpoints to the lowest and highest blocks" {
  source "$FW"
  hist=(40 90)            # 40 °C -> ▁, 90 °C -> █
  run sparkline
  [ "$output" = "▁█" ]
}

@test "sparkline clamps values outside the 40-90 range" {
  source "$FW"
  hist=(20 200)           # below 40 clamps to ▁, above 90 clamps to █
  run sparkline
  [ "$output" = "▁█" ]
}

# --- tcolor: colour a temperature by how hot it is ---------------------------
# Force the colour vars after sourcing (they are empty without a TTY) so the
# bucket each temperature lands in is observable.

@test "tcolor picks the right bucket for each band" {
  source "$FW"
  OFF_BELOW=58; G=GREEN C=CYAN Y=YELLOW R=RED
  run tcolor 50; [ "$output" = "GREEN" ]   # below the off-threshold
  run tcolor 65; [ "$output" = "CYAN" ]    # off-threshold .. 70
  run tcolor 75; [ "$output" = "YELLOW" ]  # 70 .. 82
  run tcolor 90; [ "$output" = "RED" ]     # above 82
}

# --- smoke: the script is syntactically sound and sources cleanly ------------

@test "script sources without error" {
  source "$FW"
}
