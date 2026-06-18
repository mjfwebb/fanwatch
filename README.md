# fanwatch

A live terminal monitor for fan speed and temperatures on a Lenovo ThinkPad
P15 Gen 2i whose fans are managed by
[`thinkfan`](https://github.com/vmatare/thinkfan). It reads the same EC sensors
thinkfan uses, so what you see is what thinkfan is acting on.

Each refresh shows CPU and GPU temperatures with a trend arrow (`▲` rising,
`▼` falling, `—` steady) against the previous sample, the live thinkfan level
(`0` is off, up to `7` / `full-speed` / `disengaged`) and the current fan RPM,
and a sparkline of recent CPU history (the last 40 samples, scaled 40 to
90 °C) so you can see the shape of the trend at a glance.

Temperatures are colour-coded: green below the off-threshold, cyan up to 70 °C,
yellow to 82 °C, red above. The off-threshold is read automatically from
`/etc/thinkfan.yaml` (the lowest non-zero fan level's lower bound), so it never
goes stale when you retune the curve.

When the fan level changes, fanwatch prints a callout line such as
`└─ fan level 2 → 0  ✓ fan OFF (silent)`. When CPU temperature jumps by at least
`FANWATCH_RISE` °C (default 3) between samples, it prints a culprit line naming
the processes most likely responsible:
`└─ ▲ +13°C  likely: brave 212% · gnome-shell 23% · claude 21%  │ gpu: gnome-shell`.

## Install

One line, no clone needed, and re-running the same line updates an existing
install in place:

```bash
curl -fsSL https://raw.githubusercontent.com/mjfwebb/fanwatch/main/install.sh | bash
```

It installs to `~/.local/bin` (override with `FANWATCH_BIN_DIR`), which must be
on your PATH. fanwatch only reads `/proc` and `/sys`, so it needs no root and no
udev setup.

From a checkout instead:

```bash
install -Dm755 fanwatch ~/.local/bin/fanwatch
```

The installed copy is a snapshot; re-run either line after pulling or editing
the script to update it. Once installed, `fanwatch update` does this for you,
re-running the installer in place, and `FANWATCH_RAW_URL` selects a fork or
branch.

## Usage

```bash
fanwatch        # refresh every 2 s (default)
fanwatch 5      # refresh every 5 s
fanwatch update # self-update in place
```

Press `Ctrl+C` to quit. No root required.

The rise threshold that triggers culprit attribution is configurable:

```bash
FANWATCH_RISE=5 fanwatch    # only investigate jumps of 5 °C or more
```

## How it reads things

| Value | Source |
|-------|--------|
| CPU / GPU temp | `/proc/acpi/ibm/thermal` (fields 1 and 2) |
| fan level & RPM | `/proc/acpi/ibm/fan` (`level:` / `speed:` lines) |
| off-threshold | parsed from `/etc/thinkfan.yaml` levels (fallback 58 °C) |
| CPU culprit | `top -bn2` recent %CPU, names via `/proc/<pid>/cmdline`, summed per name |
| GPU culprit | `nvidia-smi pmon -c 1` (works in hybrid/Optimus mode) |

Temperature lags load, so the culprit is whatever has been hammering the CPU or
GPU over the last moment. CPU usage comes from `top`'s second iteration (recent
%CPU, not the lifetime average `ps` reports), aggregated by program name so
multi-process apps like browsers show their true combined total. GPU
attribution uses `nvidia-smi pmon`, which works even in hybrid/Optimus mode.
This investigation runs only on a rise, so the steady-state loop stays cheap.

> Note: fanwatch reports the EC's actual fan level. If the ThinkPad firmware
> overrides thinkfan on a fast thermal spike you will see `disengaged` here.
> That is the hardware safety doing its job, not a bug.

## Contributing

Tests live in `tests/` and run with
[bats](https://github.com/bats-core/bats-core) (`bats tests`); CI also runs
`shellcheck`. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and conventions.

## License

Released under the [MIT License](LICENSE).
