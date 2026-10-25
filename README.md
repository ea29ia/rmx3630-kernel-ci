# rmx3630-kernel-ci

Kernel rebuild for **Realme 10 (RMX3630, MT6789, ColorOS 14.0.0.420EX01)** in GitHub Actions.

Goal: enable the kernel features Docker/runc needs, while keeping the **stock vendor modules loadable**
(so Wi-Fi, camera, touch and the rest keep working on the stock ROM):

- `CONFIG_PID_NS`, `CONFIG_IPC_NS`, `CONFIG_USER_NS`
- `CONFIG_SYSVIPC`, `CONFIG_POSIX_MQUEUE`
- `CONFIG_CGROUP_PIDS`, `CONFIG_CGROUP_DEVICE`
- `CONFIG_VXLAN`, `CONFIG_MACVLAN`, `CONFIG_IPVLAN`, `CONFIG_BRIDGE_NETFILTER`,
  `CONFIG_NETFILTER_XT_MATCH_ADDRTYPE`

Base: official `realme-kernel-opensource/realme10-AndroidU-kernel-source` (5.10.198) + official
`realme10-AndroidU-vendor-source`, built with the same compiler family as the stock kernel
(Android clang `r416183b`, 12.0.5), pinned to the stock release string
`5.10.209-android12-9-o-05206-g23c1467af8f7`.

## What CI proves before anything is flashed

`expected/` contains, extracted from the device's own 232 vendor modules:

- `stock_versions.tsv` — every `__versions` symbol and the CRC the module expects;
- `stock_module_exports.tsv` — symbols exported by vendor modules themselves (not the kernel's job);
- `stock_kernel_required.tsv` — symbols the kernel must export with exactly these CRCs.

`scripts/compare_symbols.py` diffs those against the freshly built `Module.symvers` and reports:

- how many required symbols are present with the expected CRC;
- which symbols are missing or changed;
- which stock modules would fail to load, and why.

The report is **a gate, not a log**: the script exits non-zero when `VERDICT` is `FAIL`, and the
workflow surfaces that as a red job. A second gate, `Release string gate (vermagic)`, asserts that
`include/config/kernel.release` equals `expected/release.txt` exactly — its main job is to catch the
dirty-tree `+` suffix that silently breaks vermagic for all 232 stock modules.

Both gates run with `if: always()`, so a failed gate still uploads the artifacts for inspection,
but the run is red and the image must be treated as non-flashable.

`LOCALVERSION=` is pinned to an empty value in `scripts/fetch.sh`; upstream `setlocalversion` skips
the `+` suffix when that variable is *set*, which is why the release string stays clean even though
`configure.sh` patches the tree.

No device writes happen in CI. Flashing `boot_a` is a separate manual step and requires explicit
approval.

## Build caching

Two caches keep repeat runs short:

- **ccache** (`CCACHE_DIR=.ccache`, 3 GB, compressed) wraps `clang`/`clang++`/`gcc`/`g++`
  via `CC="ccache clang"` in `scripts/{configure,build}.sh`. The key carries `github.run_id`
  and falls back by prefix, so each run restores the previous cache and saves its own;
  `CCACHE_SLOPPINESS=time_macros,include_file_mtime,file_macro` is required by kernel sources.
- **clang toolchain** (`clang-r416183b-tar-v1`, ~700 MB) is restored instead of re-downloaded;
  the fetch step skips the tarball when `bin/clang` already exists.

`ccache --show-stats` runs after the build and in `scripts/build.sh`, so the hit rate is visible
in the log (`cache hit (direct)` should dominate on a second run with unchanged sources).

## Manual run

```bash
gh workflow run build.yml -R ea29ia/rmx3630-kernel-ci
gh run watch -R ea29ia/rmx3630-kernel-ci
```

Artifacts: `Image.gz`, `Image`, `System.map`, `Module.symvers`, `kernel.config`, `modules.tar.gz`,
`crc-report.txt`.

## Status / risks

- The OEM source is 5.10.198, the phone runs 5.10.209 (11 stable releases + Oplus patches later than
  the published tree). KMI CRC compatibility is checked in CI; OEM-specific symbols may differ.
- If some CRCs differ, the fallback is rebuilding the affected vendor modules from the same tree and
  delivering them separately (vendor_dlkm / systemless overlay) — not done by this workflow.
- Kernel command line comes from `configs/rmx3630_defconfig` (`CONFIG_CMDLINE_EXTEND`) and matches the
  stock build.
