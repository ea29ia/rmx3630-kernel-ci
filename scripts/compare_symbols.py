#!/usr/bin/env python3
"""Compare built Module.symvers against the CRCs stock vendor modules expect."""
import os
import sys
from collections import defaultdict

def load_symvers(path):
    out = {}
    with open(path, errors="replace") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            try:
                crc = int(parts[0], 16)
            except ValueError:
                continue
            name, module = parts[1], parts[2]
            if name not in out or module == "vmlinux":
                out[name] = (crc, module)
    return out

def load_pairs(path):
    out = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            name, crc = line.split("\t")
            out[name] = int(crc, 16)
    return out

def load_refs(path):
    out = defaultdict(list)
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            module, name, crc = line.split("\t")
            out[module].append((name, int(crc, 16)))
    return out

def main():
    if len(sys.argv) < 3:
        print("usage: compare_symbols.py <out-dir> <expected-dir>", file=sys.stderr)
        return 2
    out_dir, expected_dir = sys.argv[1], sys.argv[2]
    symvers = os.path.join(out_dir, "Module.symvers")
    required = load_pairs(os.path.join(expected_dir, "stock_kernel_required.tsv"))
    refs = load_refs(os.path.join(expected_dir, "stock_module_versions.tsv"))
    kernel_required = set(required)

    if not os.path.exists(symvers):
        print(f"FAIL: {symvers} not found")
        return 1
    built = load_symvers(symvers)

    missing, mismatch, ok = [], [], []
    for name, crc in required.items():
        entry = built.get(name)
        if entry is None:
            missing.append(name)
        elif entry[0] != crc:
            mismatch.append((name, crc, entry[0], entry[1]))
        else:
            ok.append(name)

    bad_modules = []
    for module, entries in refs.items():
        miss, mism = [], []
        for name, crc in entries:
            if name not in kernel_required:
                continue  # provided by another stock vendor module
            entry = built.get(name)
            if entry is None:
                miss.append(name)
            elif entry[0] != crc:
                mism.append(name)
        if miss or mism:
            bad_modules.append((module, miss, mism))
    bad_modules.sort(key=lambda x: (-(len(x[1]) + len(x[2])), x[0]))

    lines = []
    lines.append("== stock vendor module compatibility ==")
    lines.append(f"kernel-required symbols: {len(required)}")
    lines.append(f"  present, CRC match : {len(ok)}")
    lines.append(f"  CRC mismatch       : {len(mismatch)}")
    lines.append(f"  missing            : {len(missing)}")
    lines.append(f"stock modules analyzed: {len(refs)}")
    lines.append(f"modules that would fail to load: {len(bad_modules)}")
    if mismatch:
        lines.append("")
        lines.append("CRC mismatches (symbol, expected, built, built-by):")
        for name, exp, got, mod in mismatch[:80]:
            lines.append(f"  {name}: expected {exp:08x}, built {got:08x} ({mod})")
    if missing:
        lines.append("")
        lines.append("Missing from built kernel (first 80):")
        lines.extend(f"  {n}" for n in sorted(missing)[:80])
    if bad_modules:
        lines.append("")
        lines.append("Modules -> unresolved kernel-required symbols:")
        for module, miss, mism in bad_modules[:80]:
            detail = []
            if miss:
                detail.append(f"missing={len(miss)}")
            if mism:
                detail.append(f"crc={len(mism)}")
            sample = ", ".join((miss + mism)[:4])
            lines.append(f"  {module}: {' '.join(detail)} [{sample}]")
    verdict = "PASS" if not mismatch and not missing else "FAIL"
    lines.append("")
    lines.append(f"VERDICT: {verdict}")

    report = "\n".join(lines)
    print(report)
    with open(os.path.join(out_dir, "crc-report.txt"), "w") as fh:
        fh.write(report + "\n")
    return 0

if __name__ == "__main__":
    sys.exit(main())
