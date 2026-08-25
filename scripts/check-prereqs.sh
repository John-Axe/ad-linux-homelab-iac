#!/usr/bin/env bash
#
# check-prereqs.sh — verify the host has what `vagrant up` needs before
# attempting to bring the lab up: VirtualBox, Vagrant, and enough free
# RAM/disk for 1 Windows Server DC (4GB RAM) + 3 Ubuntu servers (1GB each).
#
# Exits non-zero (and prints exactly what's missing) if anything required
# is absent, so this can be used as a pre-flight gate in a Makefile/CI step
# as well as run manually.

set -uo pipefail

# Minimum recommended headroom for dc01 (4096MB) + 3x linux nodes (1024MB
# each) = 7168MB of VM RAM. Require a bit more free on the host so the
# host OS itself isn't starved.
REQUIRED_RAM_MB=8192
REQUIRED_DISK_GB=40

fail=0

pass() { printf '  [OK]   %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }
err()  { printf '  [FAIL] %s\n' "$1"; fail=1; }

echo "== ad-linux-homelab-iac prerequisite check =="
echo

echo "-- Hypervisor / provisioning tools --"
if command -v VBoxManage >/dev/null 2>&1; then
    pass "VirtualBox found: $(VBoxManage --version 2>/dev/null)"
else
    err "VirtualBox (VBoxManage) not found on PATH. Install from https://www.virtualbox.org/wiki/Downloads"
fi

if command -v vagrant >/dev/null 2>&1; then
    pass "Vagrant found: $(vagrant --version 2>/dev/null)"
else
    err "Vagrant not found on PATH. Install from https://developer.hashicorp.com/vagrant/install"
fi

if command -v packer >/dev/null 2>&1; then
    pass "Packer found: $(packer --version 2>/dev/null) (optional — not required by this repo's Vagrantfile)"
else
    warn "Packer not found (optional; only needed if you build your own boxes instead of using published ones)"
fi

echo
echo "-- Memory --"
if command -v free >/dev/null 2>&1; then
    # MemAvailable is the kernel's own estimate of what's actually
    # reclaimable/usable, closer to reality than raw MemFree.
    avail_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
    if [ -n "${avail_mb:-}" ]; then
        if [ "$avail_mb" -ge "$REQUIRED_RAM_MB" ]; then
            pass "Available RAM: ${avail_mb}MB (>= ${REQUIRED_RAM_MB}MB recommended)"
        else
            err "Available RAM: ${avail_mb}MB (< ${REQUIRED_RAM_MB}MB recommended for dc01 + 3 Linux nodes)"
        fi
    else
        warn "Could not read /proc/meminfo to check available RAM"
    fi
elif command -v sysctl >/dev/null 2>&1; then
    # macOS
    total_bytes=$(sysctl -n hw.memsize 2>/dev/null)
    if [ -n "${total_bytes:-}" ]; then
        total_mb=$((total_bytes / 1024 / 1024))
        if [ "$total_mb" -ge "$REQUIRED_RAM_MB" ]; then
            pass "Total RAM: ${total_mb}MB (>= ${REQUIRED_RAM_MB}MB recommended; macOS total, not available)"
        else
            err "Total RAM: ${total_mb}MB (< ${REQUIRED_RAM_MB}MB recommended)"
        fi
    fi
else
    warn "No known way to check RAM on this OS — verify manually (need ~${REQUIRED_RAM_MB}MB free)"
fi

echo
echo "-- Disk space --"
if command -v df >/dev/null 2>&1; then
    avail_kb=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "${avail_kb:-}" ]; then
        avail_gb=$((avail_kb / 1024 / 1024))
        if [ "$avail_gb" -ge "$REQUIRED_DISK_GB" ]; then
            pass "Free disk on \$HOME filesystem: ${avail_gb}GB (>= ${REQUIRED_DISK_GB}GB recommended)"
        else
            err "Free disk on \$HOME filesystem: ${avail_gb}GB (< ${REQUIRED_DISK_GB}GB recommended for 4 VM disks + box cache)"
        fi
    else
        warn "Could not determine free disk space"
    fi
else
    warn "'df' not available — verify manually (need ~${REQUIRED_DISK_GB}GB free)"
fi

echo
echo "-- Virtualization extensions (best-effort) --"
if command -v egrep >/dev/null 2>&1 && [ -r /proc/cpuinfo ]; then
    if egrep -q '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
        pass "CPU virtualization extensions (VT-x/AMD-V) present in /proc/cpuinfo"
    else
        warn "No vmx/svm flags found in /proc/cpuinfo — if this host is itself a VM or container, nested virtualization may not be available; VirtualBox will fail to start guests"
    fi
else
    warn "Could not check /proc/cpuinfo for virtualization extensions on this OS"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "All required checks passed. Run 'vagrant up' from the repo root."
    exit 0
else
    echo "One or more required checks failed — see [FAIL] lines above."
    echo "This is expected in most CI/sandboxed containers (no nested"
    echo "virtualization); see README.md's Verification section."
    exit 1
fi
