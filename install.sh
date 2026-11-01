#!/usr/bin/env bash
# Kept for published one-liners, and older minions' upgrades, that still call install.sh; the
# installer is installGhostwireMinion.sh beside it. Piped from curl, this downloads that one and
# runs it with the same arguments.
set -euo pipefail

main() {
  local here="" script
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  fi
  if [ -n "$here" ] && [ -f "$here/installGhostwireMinion.sh" ]; then
    exec bash "$here/installGhostwireMinion.sh" "$@"
  fi
  script=$(curl -fsSL https://raw.githubusercontent.com/garethcheyne/ghostwire-minion/main/installGhostwireMinion.sh) \
    || { echo "Couldn't download installGhostwireMinion.sh from GitHub." >&2; exit 1; }
  exec bash -c "$script" installGhostwireMinion.sh "$@"
}

main "$@"
