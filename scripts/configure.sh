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
JOBS="${JOBS:-$(nproc)}"
if [ -n "${MAKEFLAGS:-}" ]; then
  J=$(echo "${MAKEFLAGS}" | grep -oE '\-j[0-9]+' | tr -d 'j-')
  [ -n "$J" ] && JOBS="$J"
fi
case "$JOBS" in (*[!0-9]*|'') JOBS=2;; esac
echo "configuring with -j$JOBS"
MAKE=(make -C "$WORK/kernel" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1
       CROSS_COMPILE=aarch64-linux-gnu- -j"$JOBS"
       CC="${CCACHE_WRAP}clang" CXX="${CCACHE_WRAP}clang++"
       HOSTCC="${CCACHE_WRAP}gcc" HOSTCXX="${CCACHE_WRAP}g++")

# Our source is 5.10.198; the device runs 5.10.209 and its modules carry that
# release in vermagic, so the built kernel must report the same version.
sed -i 's/^SUBLEVEL = .*/SUBLEVEL = 209/' "$WORK/kernel/Makefile"

cp "$GITHUB_WORKSPACE/configs/rmx3630_defconfig" \
   "$WORK/kernel/arch/arm64/configs/rmx3630_defconfig"

"${MAKE[@]}" rmx3630_defconfig

# Release string MUST be applied in ALL modes (baseline included): the OEM
# defconfig carries LOCALVERSION="" + LOCALVERSION_AUTO=y, and with AUTO=y
# setlocalversion appends "-g<sha>-dirty" from the build tree, which no
# stock module's vermagic contains. This was the failure of run 40316350101:
# built 5.10.209-o-g01f8dc938ab9-dirty != expected 5.10.209-android12-9-o-05206-g23c1467af8f7.
"$WORK/kernel/scripts/config" --file "$OUT/.config" \
  --set-str LOCALVERSION "-android12-9-o-05206-g23c1467af8f7" \
  --disable LOCALVERSION_AUTO

if [ "${STOCK_CONFIG_ONLY:-0}" = "1" ]; then
  echo "::warning::STOCK_CONFIG_ONLY=1 - skipping the Docker feature set (CRC baseline)"
else
"$WORK/kernel/scripts/config" --file "$OUT/.config" \
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

# /proc/config.gz of the STOCK phone (pulled 2026-10-26, diff vs our build =
# 18 lines) proves the stock kernel was built WITH LTO_CLANG_FULL + CFI_CLANG:
# stock vendor modules require __cfi_slowpath (exp CRC 2cd90edd) and the stock
# config has LTO=y/LTO_CLANG=y/LTO_CLANG_FULL=y/CFI_CLANG=y. The earlier
# "no llvm-lto marker in vermagic" inference was wrong (MODULE_SCMVERSION=y
# builds vermagic from the SCM string instead). LTO/CFI change struct module
# and core type CRCs -> they are REQUIRED for CRC parity, not optional.
"$WORK/kernel/scripts/config" --file "$OUT/.config" \
  --enable LTO \
  --enable LTO_CLANG \
  --enable LTO_CLANG_FULL \
  --disable LTO_CLANG_THIN \
  --disable LTO_NONE \
  --enable CFI_CLANG \
  --enable CFI_CLANG_SHADOW \
  --disable CFI_PERMISSIVE \
  --enable MODULE_SCMVERSION
# Stock FRAME_WARN is 3600; match it exactly now that LTO (as on stock) changes
# inlining again. If -Werror trips on a frame, that is a real source-delta
# signal, not something to paper over with a bigger limit.
"$WORK/kernel/scripts/config" --file "$OUT/.config" \
  --set-val FRAME_WARN 3600
"${MAKE[@]}" olddefconfig

echo "kernelrelease: $(cat "$OUT/include/config/kernel.release" 2>/dev/null || true)"

# NOTE: STOCK_CONFIG_ONLY=1 is the CRC baseline experiment - it must stay
# reachable from the workflow so the "config delta vs source version" question
# can be re-asked at any time without rewriting the script.
