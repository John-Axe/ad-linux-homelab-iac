#!/usr/bin/env bash
#
# teardown.sh — destroy all lab VMs and reset local Vagrant state, so the
# next `vagrant up` is a clean provision from scratch.
#
# Usage:
#   ./scripts/teardown.sh          # destroy VMs, keep downloaded boxes
#   ./scripts/teardown.sh --full   # also remove the cached Vagrant boxes
#                                   # (dc01's Windows box especially is a
#                                   # multi-GB download — only pass --full
#                                   # if you actually want to re-download it)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v vagrant >/dev/null 2>&1; then
    echo "vagrant not found on PATH — nothing to tear down via Vagrant." >&2
    echo "If VMs were created some other way, remove them manually." >&2
    exit 1
fi

echo "Destroying all VMs defined in this Vagrantfile (dc01, db01, web02, files01)..."
vagrant destroy -f

echo "Removing local .vagrant/ state directory..."
rm -rf .vagrant

if [ "${1:-}" = "--full" ]; then
    echo "Removing cached Vagrant boxes used by this lab..."
    vagrant box remove gusztavvargadr/windows-server --force 2>/dev/null || true
    vagrant box remove ubuntu/jammy64 --force 2>/dev/null || true
    echo "Boxes removed — next 'vagrant up' will re-download them."
else
    echo "Cached boxes left in place (re-run with --full to remove them too)."
fi

echo "Teardown complete."
