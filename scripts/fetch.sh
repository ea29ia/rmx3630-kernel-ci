#!/usr/bin/env bash
# Fetch pinned OEM kernel + vendor trees and lay out the sibling `vendor` path
# the in-tree Oplus symlinks expect.
set -euo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
WORK="${WORK:-$GITHUB_WORKSPACE/work}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/realme-kernel-opensource/realme10-AndroidU-kernel-source.git}"
VENDOR_REPO="${VENDOR_REPO:-https://github.com/realme-kernel-opensource/realme10-AndroidU-vendor-source.git}"
KERNEL_SHA="${KERNEL_SHA:-01f8dc938ab93110bac0e72b2d235f279b4de614}"
VENDOR_SHA="${VENDOR_SHA:-e92b9be280b5f8cf299c2bde1c5cf29cc3e98ba3}"

mkdir -p "$WORK"
rm -rf "$WORK/kernel" "$WORK/vendor-src" "$WORK/vendor" "$WORK/out"

echo "::group::kernel source"
git clone --depth 1 "$KERNEL_REPO" "$WORK/kernel"
got="$(git -C "$WORK/kernel" rev-parse HEAD)"
if [ "$got" != "$KERNEL_SHA" ]; then
  echo "kernel HEAD mismatch: $got != $KERNEL_SHA" >&2
  exit 1
fi
echo "kernel: $got"

# The release string must come out byte-identical to stock:
#   5.10.209-android12-9-o-05206-g23c1467af8f7
# scripts/setlocalversion appends "+" whenever the tree is dirty, and
# configure.sh *does* dirty it (patched Makefile + dropped-in defconfig).
# A "+" changes vermagic, so every stock vendor module would refuse to load.
# Upstream skips the suffix when LOCALVERSION is *set* (even to an empty
# value): "if test \"${LOCALVERSION+set}\" != \"set\"; then ...". Pin it here
# and let the "Release string gate" step assert the result.
printf 'LOCALVERSION=\n' >> "${GITHUB_ENV:-/dev/null}"
export LOCALVERSION=
test "${LOCALVERSION+set}" = "set"
echo "LOCALVERSION pinned (empty) to suppress the dirty-tree '+' suffix"
echo "::endgroup::"

echo "::group::vendor source"
git clone --depth 1 "$VENDOR_REPO" "$WORK/vendor-src"
got="$(git -C "$WORK/vendor-src" rev-parse HEAD)"
if [ "$got" != "$VENDOR_SHA" ]; then
  echo "vendor HEAD mismatch: $got != $VENDOR_SHA" >&2
  exit 1
fi
echo "vendor: $got"
# in-tree symlinks point at <parent>/vendor/oplus/... while the repo root has
# vendor/oplus/..., so link to the inner directory
ln -sfn "$WORK/vendor-src/vendor" "$WORK/vendor"
# OEM vendor code includes ".../kernel-5.10/<path>" relative to its own
# location; the OEM build tree expects a kernel-5.10 entry next to the vendor
# tree, so point it at the kernel checkout.
ln -sfn "$WORK/kernel" "$WORK/vendor-src/vendor/kernel-5.10"
test -e "$WORK/vendor-src/vendor/kernel-5.10/drivers/power/supply/charger_class.h"
echo "::endgroup::"

echo "::group::symlink sanity"
bad=0
while IFS= read -r link; do
  if [ ! -e "$link" ]; then
    echo "BROKEN: ${link#"$WORK/kernel"/} -> $(readlink "$link")"
    bad=$((bad + 1))
  fi
done < <(find "$WORK/kernel/drivers" "$WORK/kernel/kernel" "$WORK/kernel/mm" \
          "$WORK/kernel/include" "$WORK/kernel/sound" -type l)
echo "broken symlinks: $bad"
echo "::endgroup::"
[ "$bad" -eq 0 ]
