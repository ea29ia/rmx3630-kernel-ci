#!/usr/bin/env bash
# Configure the OEM tree: stock release string + Docker/runc feature set.
set -euo pipefail

: "${GITHUB_WORKSPACE:?}"
WORK="${WORK:-$GITHUB_WORKSPACE/work}"
OUT="${OUT:-$WORK/out}"
: "${CLANG_DIR:?CLANG_DIR is required}"

export PATH="$CLANG_DIR/bin:$PATH"
MAKE=(make -C "$WORK/kernel" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1
       CROSS_COMPILE=aarch64-linux-gnu-)

# Our source is 5.10.198; the device runs 5.10.209 and its modules carry that
# release in vermagic, so the built kernel must report the same version.
sed -i 's/^SUBLEVEL = .*/SUBLEVEL = 209/' "$WORK/kernel/Makefile"

cp "$GITHUB_WORKSPACE/configs/rmx3630_defconfig" \
   "$WORK/kernel/arch/arm64/configs/rmx3630_defconfig"

"${MAKE[@]}" rmx3630_defconfig

"$WORK/kernel/scripts/config" --file "$OUT/.config" \
  --set-str LOCALVERSION "-android12-9-o-05206-g23c1467af8f7" \
  --disable LOCALVERSION_AUTO \
  --enable PID_NS \
  --enable IPC_NS \
  --enable USER_NS \
  --enable SYSVIPC \
  --enable POSIX_MQUEUE \
  --enable CGROUP_PIDS \
  --enable CGROUP_DEVICE \
  --enable VXLAN \
  --enable MACVLAN \
  --enable IPVLAN \
  --enable BRIDGE_NETFILTER \
  --enable NETFILTER_XT_MATCH_ADDRTYPE \
  --enable LTO_CLANG_THIN \
  --disable LTO_CLANG_FULL \
  --disable DEBUG_INFO \
  --disable DEBUG_INFO_DWARF4 \
  --disable DEBUG_INFO_BTF \
  --disable GDB_SCRIPTS

"${MAKE[@]}" olddefconfig

echo "::group::configured values"
grep -E '^CONFIG_(LOCALVERSION|LOCALVERSION_AUTO|PID_NS|IPC_NS|USER_NS|SYSVIPC|POSIX_MQUEUE|CGROUP_PIDS|CGROUP_DEVICE|VXLAN|MACVLAN|IPVLAN|BRIDGE_NETFILTER|NETFILTER_XT_MATCH_ADDRTYPE|LTO_CLANG_THIN|LTO_CLANG_FULL|DEBUG_INFO|CFI_CLANG|PREEMPT|MODVERSIONS|MODULE_UNLOAD|SMP)=' \
  "$OUT/.config" || true
echo "::endgroup::"

# Fail early if a required switch silently disappeared (Kconfig deps).
missing=0
for opt in PID_NS IPC_NS USER_NS SYSVIPC POSIX_MQUEUE CGROUP_PIDS CGROUP_DEVICE; do
  if ! grep -q "^CONFIG_${opt}=y$" "$OUT/.config"; then
    echo "required option not enabled: CONFIG_${opt}" >&2
    missing=$((missing + 1))
  fi
done
[ "$missing" -eq 0 ]

echo "kernelrelease: $(cat "$OUT/include/config/kernel.release" 2>/dev/null || true)"
