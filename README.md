# fanwatch

A live terminal monitor for fan speed and temperatures on Linux and macOS. It
reads from whatever the machine exposes: on a Lenovo ThinkPad it uses
`thinkpad_acpi` (and pairs with
[`thinkfan`](https://github.com/vmatare/thinkfan) when present), on other Linux
machines it falls back to the generic
[`hwmon`](https://docs.kernel.org/hwmon/sysfs-interface.html) sysfs interface,
and on macOS it reads the SMC through a helper tool. The backend is
auto-detected; force one with `FANWATCH_BACKEND`.

![fanwatch output: a pinned header above timestamped rows of CPU and GPU temperatures (green when cool, cyan, yellow, then red as they climb) each with a trend arrow, the fan's commanded level and RPM, and a sparkline of recent CPU history, with callout lines blaming a thermal spike on brave → gnome-shell → claude and tracking the fan as it spins up and later switches off silently](example.svg)

Each refresh shows CPU and GPU temperatures with a trend arrow (`▲` rising,
`▼` falling, `—` steady) against the previous sample, the current fan RPM, the
fan's commanded level (a named thinkfan level like `0` / `full-speed` on the
thinkpad backend, or a PWM percentage on hwmon), and a sparkline of recent CPU
history (the last 40 samples, scaled 40 to 90 °C).

Temperatures are colour-coded: green when cool, cyan up to 70 °C, yellow to
82 °C, red above. On the thinkpad backend "cool" is read automatically from
`/etc/thinkfan.yaml` (the lowest non-zero fan level's lower bound), so it tracks
your fan curve; on the hwmon backend it is `FANWATCH_OFF_BELOW` (default 55 °C).

When the fan turns on or off (and on ThinkPads, on any level change) fanwatch
prints a callout line such as `└─ fan 2 → 0  ✓ fan OFF (silent)`. When CPU
temperature jumps by at least `FANWATCH_RISE` °C (default 3) between samples, it
prints a culprit line naming the processes most likely responsible:
`└─ ▲ +13°C  likely: brave 212% · gnome-shell 23% · claude 21%  │ gpu: gnome-shell`.

By default the header is pinned to the top of the terminal while the rows scroll
beneath it. Press `Shift+Tab` to switch to a scrolling layout that keeps the
history in your terminal's scrollback, or start there with `--no-sticky` (or
`FANWATCH_STICKY=0`). `Shift+Tab` toggles between the two while running.

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
fanwatch             # refresh every 2 s (default), header pinned
fanwatch 5           # refresh every 5 s
fanwatch --no-sticky # scrolling layout instead of a pinned header
fanwatch update      # self-update in place
```

Press `Ctrl+C` to quit, and `Shift+Tab` to toggle the pinned and scrolling
layouts while running. No root required.

The rise threshold that triggers culprit attribution is configurable:

```bash
FANWATCH_RISE=5 fanwatch    # only investigate jumps of 5 °C or more
```

## Backends

fanwatch auto-detects the best available source. Override it with
`FANWATCH_BACKEND=thinkpad`, `hwmon`, or `macos`.

- **thinkpad** *(preferred when present)* reads `/proc/acpi/ibm/thermal` and
  `/proc/acpi/ibm/fan`, giving named fan levels (`0` … `7` / `full-speed` /
  `disengaged`) and the thinkfan-derived off-threshold.
- **hwmon** is the generic Linux fallback. It reads `/sys/class/hwmon`: CPU temp
  from `coretemp` / `k10temp` / `zenpower` / `acpitz`, GPU temp from `amdgpu` (or
  `nvidia-smi`), fan RPM from `fan*_input`, and the fan level from `pwm*` shown as
  a percentage of 255.
- **macos** reads the SMC through a helper tool on your PATH (auto-detected in
  this order, or forced with `FANWATCH_MAC_TOOL`): [`smctemp`](https://github.com/narugit/smctemp)
  (CPU/GPU temp and fan, Intel and Apple Silicon), `istats` (CPU temp and fan),
  `osx-cpu-temp` (CPU temp), or `sudo powermetrics` (CPU temp, **Intel only**;
  it is skipped during auto-detection on Apple Silicon, where its sampler does
  not expose the CPU die temperature). None ship with macOS, so install one:

  ```bash
  brew tap narugit/tap && brew install narugit/tap/smctemp   # recommended
  brew install osx-cpu-temp                                  # CPU temp only
  gem install iStats                                         # istats (a Ruby gem)
  ```

  fanwatch prints these same hints if it starts and finds no helper. macOS
  exposes no commanded PWM, so the fan column shows `on`/`off` from RPM; fanless
  Macs (and Apple Silicon with no fan sensor) report no fan.

On the hwmon backend you can point fanwatch at specific sensors instead of
letting it auto-detect, by giving sysfs paths:

```bash
FANWATCH_CPU_TEMP=/sys/class/hwmon/hwmon7/temp1_input \
FANWATCH_FAN="/sys/class/hwmon/hwmon8/fan1_input /sys/class/hwmon/hwmon8/fan2_input" \
FANWATCH_PWM=/sys/class/hwmon/hwmon8/pwm1 fanwatch
```

(`FANWATCH_GPU_TEMP` works the same way.)

## How it reads things

| Value | thinkpad backend | hwmon backend | macos backend |
|-------|------------------|---------------|---------------|
| CPU / GPU temp | `/proc/acpi/ibm/thermal` (fields 1 and 2) | `temp*_input` (millidegrees), labels matched per chip | SMC via the helper tool (GPU only on `smctemp`) |
| fan RPM | `/proc/acpi/ibm/fan` `speed:` | `fan*_input` (multiple fans joined `a/b`) | helper tool (fastest fan) |
| fan level | `/proc/acpi/ibm/fan` `level:` | `pwm*` as a percentage of 255 | `on`/`off` from RPM (no PWM exposed) |
| off-threshold | parsed from `/etc/thinkfan.yaml` (fallback 58 °C) | `FANWATCH_OFF_BELOW` (default 55 °C) | `FANWATCH_OFF_BELOW` (default 55 °C) |
| CPU culprit | `top -bn2` recent %CPU, names via `/proc/<pid>/cmdline`, summed per name | same | `ps -Ac -o pcpu,comm`, summed per name |
| GPU culprit | `nvidia-smi pmon -c 1` (works in hybrid/Optimus mode) | same | n/a |

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
