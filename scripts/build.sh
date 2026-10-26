#!/usr/bin/env bash
# Build Image (and gzip it the way the stock boot image stores it), then try to
# build modules. Modules are best-effort: Module.symvers is what the CRC check
# needs, and a partial module build is not fatal for the kernel artifact.
set -euo pipefail

: "${GITHUB_WORKSPACE:?}"
WORK="${WORK:-$GITHUB_WORKSPACE/work}"
OUT="${OUT:-$WORK/out}"
: "${CLANG_DIR:?CLANG_DIR is required}"

export PATH="$CLANG_DIR/bin:$PATH"
CCACHE_WRAP=""
if command -v ccache >/dev/null 2>&1; then
  CCACHE_WRAP="ccache "
fi
JOBS="${JOBS:-$(nproc)}"
if [ -n "${MAKEFLAGS:-}" ]; then
  # MAKEFLAGS=-jN takes precedence (memory-constrained baseline runs)
  JOBS=$(echo "${MAKEFLAGS}" | grep -oE '\-j[0-9]+' | tr -d 'j' || true)
  [ -n "$JOBS" ] || JOBS=2
fi
echo "building with -j$JOBS"
MAKE=(make -C "$WORK/kernel" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1
       CROSS_COMPILE=aarch64-linux-gnu- -j"$JOBS"
       CC="${CCACHE_WRAP}clang" CXX="${CCACHE_WRAP}clang++"
       HOSTCC="${CCACHE_WRAP}gcc" HOSTCXX="${CCACHE_WRAP}g++")

echo "::group::Image"
"${MAKE[@]}" Image
gzip -9 -n -c "$OUT/arch/arm64/boot/Image" > "$OUT/Image.gz"
ls -lh "$OUT/arch/arm64/boot/Image" "$OUT/Image.gz"
echo "::endgroup::"

echo "::group::modules (best effort)"
set +e
"${MAKE[@]}" modules
mod_rc=$?
set -e
echo "modules exit code: $mod_rc"
if [ -f "$OUT/Module.symvers" ]; then
  echo "Module.symvers: $(wc -l < "$OUT/Module.symvers") entries"
else
  echo "Module.symvers missing" >&2
  exit 1
fi
echo "::endgroup::"

if command -v ccache >/dev/null 2>&1; then
  echo "::group::ccache"
  ccache --show-stats || true
  echo "::endgroup::"
fi

echo "kernelrelease: $(cat "$OUT/include/config/kernel.release" 2>/dev/null || true)"
