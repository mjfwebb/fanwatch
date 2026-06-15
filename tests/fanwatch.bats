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
  [ "$output" = "" ]   # a single space, which bats trims to empty
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
