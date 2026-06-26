#!/usr/bin/env bash
# install.sh - install or update fanwatch without cloning the repo:
#
#   curl -fsSL https://raw.githubusercontent.com/mjfwebb/fanwatch/main/install.sh | bash
#
# Re-running the same line updates the installed copy in place. fanwatch only
# reads /proc and /sys, so no root or udev setup is needed.
#
# Overrides: FANWATCH_BIN_DIR for the install dir (default ~/.local/bin),
# FANWATCH_RAW_URL to fetch from a fork or branch.
set -euo pipefail

raw_url=${FANWATCH_RAW_URL:-https://raw.githubusercontent.com/mjfwebb/fanwatch/main}
bin_dir=${FANWATCH_BIN_DIR:-$HOME/.local/bin}

command -v curl >/dev/null || { echo "install.sh: curl is required" >&2; exit 1; }

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# Fetch to a temp file and move into place only after the download succeeded
# and looks sane, so a failed fetch never clobbers a working install.
curl -fsSL "$raw_url/fanwatch" -o "$tmp_dir/fanwatch"
head -n1 "$tmp_dir/fanwatch" | grep -q '^#!' ||
  { echo "install.sh: $raw_url/fanwatch does not look like a script, not installing" >&2; exit 1; }

# The script carries its version as a VERSION= line; read it from a file
# rather than executing it. Empty for pre-versioning installs.
script_version() { sed -n 's/^VERSION=//p' "$1" 2>/dev/null | head -n1; }

target=$bin_dir/fanwatch
new_ver=$(script_version "$tmp_dir/fanwatch")
if [[ -e $target ]] && cmp -s "$tmp_dir/fanwatch" "$target"; then
  echo "fanwatch already up to date: $target${new_ver:+ ($new_ver)}"
else
  verb=installed; old_ver=""
  [[ -e $target ]] && { verb=updated; old_ver=$(script_version "$target"); }
  install -Dm755 "$tmp_dir/fanwatch" "$target"
  case $verb in
    updated)   echo "updated $target (${old_ver:-unversioned} -> ${new_ver:-unversioned})";;
    installed) echo "installed $target${new_ver:+ ($new_ver)}";;
  esac
fi

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "note: $bin_dir is not on your PATH" >&2 ;;
esac

# --- Windows: offer to install LibreHardwareMonitor (the windows backend's source) ---
#
# fanwatch is a bash script run from Git Bash or WSL; on Windows its backend
# reads sensors from LibreHardwareMonitor (LHM). Unlike the Linux/macOS sources,
# LHM is a separate app that isn't present by default, so offer to install it.
# Everything below is a no-op off Windows.

running_on_windows() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  # WSL: a Linux kernel, but with Windows interop we can drive powershell.exe.
  grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null &&
    command -v powershell.exe >/dev/null 2>&1
}

# Prompt on the terminal even when this script was piped into bash: `curl | bash`
# leaves stdin pointing at the pipe, not the keyboard, so read from /dev/tty.
confirm() {
  local reply
  [[ -e /dev/tty ]] || return 1
  printf '%s [y/N] ' "$1" >/dev/tty
  read -r reply </dev/tty || return 1
  [[ $reply == [yY] || $reply == [yY][eE][sS] ]]
}

lhm_installed() {
  if command -v winget.exe >/dev/null 2>&1 &&
     winget.exe list -e --id LibreHardwareMonitor.LibreHardwareMonitor >/dev/null 2>&1; then
    return 0
  fi
  # winget may be absent, or LHM may be a portable copy from the zip fallback
  # below; look for the executable under %LOCALAPPDATA%\LibreHardwareMonitor.
  command -v powershell.exe >/dev/null 2>&1 || return 1
  # Single-quoted on purpose: $env:/$dir are PowerShell, not bash, variables.
  # shellcheck disable=SC2016
  powershell.exe -NoProfile -Command '
    $dir = Join-Path $env:LOCALAPPDATA "LibreHardwareMonitor"
    if (Get-ChildItem -Path $dir -Recurse -Filter LibreHardwareMonitor.exe `
          -ErrorAction SilentlyContinue | Select-Object -First 1) { exit 0 } else { exit 1 }
  ' >/dev/null 2>&1
}

install_lhm_winget() {
  command -v winget.exe >/dev/null 2>&1 || return 1
  echo "installing LibreHardwareMonitor via winget..."
  winget.exe install -e --id LibreHardwareMonitor.LibreHardwareMonitor \
    --accept-package-agreements --accept-source-agreements
}

# Fallback when winget is missing or its install fails: LHM ships as a portable
# zip (no .exe installer), so fetch the latest release and extract it. The work
# runs Windows-side in PowerShell to avoid path-conversion and unzip differences
# between Git Bash and WSL.
install_lhm_zip() {
  command -v powershell.exe >/dev/null 2>&1 || return 1
  echo "falling back to the latest LibreHardwareMonitor release zip..."
  # Single-quoted on purpose: the $vars below are PowerShell, not bash.
  # shellcheck disable=SC2016
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '
    $ErrorActionPreference = "Stop"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $api   = "https://api.github.com/repos/LibreHardwareMonitor/LibreHardwareMonitor/releases/latest"
    $rel   = Invoke-RestMethod -Uri $api -Headers @{ "User-Agent" = "fanwatch-install" }
    $asset = $rel.assets | Where-Object { $_.name -like "*net472*.zip" } | Select-Object -First 1
    if (-not $asset) { $asset = $rel.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1 }
    if (-not $asset) { throw "no .zip asset in the latest LibreHardwareMonitor release" }
    $dest = Join-Path $env:LOCALAPPDATA "LibreHardwareMonitor"
    $zip  = Join-Path $env:TEMP $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $dest -Force
    Remove-Item $zip -Force
    Write-Output ("extracted " + $asset.name + " to " + $dest)
  '
}

if running_on_windows; then
  if lhm_installed; then
    : # already present, nothing to do
  elif confirm "fanwatch's windows backend needs LibreHardwareMonitor. Install it now?"; then
    if install_lhm_winget || install_lhm_zip; then
      cat <<'EOF'

LibreHardwareMonitor installed. To use it with fanwatch:
  - run LibreHardwareMonitor as administrator (it needs admin to read CPU sensors)
  - enable Options -> Remote Web Server -> Run (default port 8085)
then start fanwatch from Git Bash or WSL.
EOF
    else
      echo "install.sh: could not install LibreHardwareMonitor automatically; get it from" >&2
      echo "  https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases" >&2
    fi
  fi
fi
