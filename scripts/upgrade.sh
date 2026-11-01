#!/usr/bin/env bash
# Kept for servers and cron jobs that still call scripts/upgrade.sh; the upgrade is ../upgradeGhostwireMinion.sh.
exec "$(dirname "$0")/../upgradeGhostwireMinion.sh" "$@"
