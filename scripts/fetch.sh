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
