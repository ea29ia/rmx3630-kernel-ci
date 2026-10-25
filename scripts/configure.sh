#!/usr/bin/env bash
# Configure the OEM tree: stock release string + Docker/runc feature set.
set -euo pipefail

: "${GITHUB_WORKSPACE:?}"
WORK="${WORK:-$GITHUB_WORKSPACE/work}"
OUT="${OUT:-$WORK/out}"
: "${CLANG_DIR:?CLANG_DIR is required}"

export PATH="$CLANG_DIR/bin:$PATH"
# Wrap the compiler in ccache when it is available: object files are keyed by
# preprocessed source + flags, so an unchanged tree rebuilds from cache.
CCACHE_WRAP=""
if command -v ccache >/dev/null 2>&1; then
  CCACHE_WRAP="ccache "
  echo "ccache: $(ccache --version | head -1) dir=$CCACHE_DIR"
fi
MAKE=(make -C "$WORK/kernel" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1
       CROSS_COMPILE=aarch64-linux-gnu-
       CC="${CCACHE_WRAP}clang" CXX="${CCACHE_WRAP}clang++"
       HOSTCC="${CCACHE_WRAP}gcc" HOSTCXX="${CCACHE_WRAP}g++")

# Our source is 5.10.198; the device runs 5.10.209 and its modules carry that
# release in vermagic, so the built kernel must report the same version.
sed -i 's/^SUBLEVEL = .*/SUBLEVEL = 209/' "$WORK/kernel/Makefile"

cp "$GITHUB_WORKSPACE/configs/rmx3630_defconfig" \
   "$WORK/kernel/arch/arm64/configs/rmx3630_defconfig"

"${MAKE[@]}" rmx3630_defconfig

if [ "${STOCK_CONFIG_ONLY:-0}" = "1" ]; then
  # Baseline experiment: leave the OEM defconfig untouched. If the stock modules'
  # CRCs match in this configuration, the 1100 mismatches we see with the Docker
  # feature set are caused by our own CONFIG delta (struct layout -> genksyms),
  # not by the 5.10.198-vs-5.10.209 difference.
  echo "::warning::STOCK_CONFIG_ONLY=1 - skipping the Docker feature set (CRC baseline)"
else
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
fi

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
if [ "${STOCK_CONFIG_ONLY:-0}" = "1" ]; then
  echo "::warning::STOCK_CONFIG_ONLY=1 - $missing required Docker option(s) missing (expected in baseline mode)"
else
  [ "$missing" -eq 0 ]
fi

echo "kernelrelease: $(cat "$OUT/include/config/kernel.release" 2>/dev/null || true)"
