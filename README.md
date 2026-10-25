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

No device writes happen in CI. Flashing `boot_a` is a separate manual step and requires explicit
approval.

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
