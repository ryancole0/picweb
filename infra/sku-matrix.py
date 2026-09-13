#!/usr/bin/env python3
"""
Find VM sizes usable in ALL of the given regions, for this subscription.

    ./sku-matrix.py eastus southcentralus swedencentral
    ./sku-matrix.py --max-vcpu 8 --min-mem 16 eastus swedencentral
    ./sku-matrix.py --all-sizes eastus            # no size filter, one region

Reads `az vm list-skus`, so it reflects YOUR subscription's restrictions, not
the public region list. Run `az login` first.

Restriction handling is the part that matters. A SKU can carry:
  type=Location -> genuinely unusable in that region. Excluded.
  type=Zone     -> unavailable in SOME availability zones only. Still usable
                   for a regional (non-zonal) deployment, which is what
                   server.bicep does, so these are KEPT and flagged.
The portal's size picker hides zone-restricted sizes, which is why a SKU can
look "not available" there and deploy fine from a template.
"""

import argparse
import json
import subprocess
import sys


def list_skus(region: str) -> list:
    try:
        raw = subprocess.run(
            ["az", "vm", "list-skus", "-l", region,
             "--resource-type", "virtualMachines", "--all", "-o", "json"],
            capture_output=True, text=True, check=True,
        ).stdout
    except FileNotFoundError:
        sys.exit("az not found on PATH")
    except subprocess.CalledProcessError as exc:
        sys.exit(f"az failed for {region}:\n{exc.stderr.strip()}")
    return json.loads(raw)


def capability(sku: dict, name: str) -> float:
    for cap in sku.get("capabilities") or []:
        if cap.get("name") == name:
            try:
                return float(cap.get("value"))
            except (TypeError, ValueError):
                return 0.0
    return 0.0


def usable(sku: dict) -> tuple:
    """Return (is_usable, zone_restricted)."""
    location_blocked = False
    zone_blocked = False
    for restriction in sku.get("restrictions") or []:
        if restriction.get("type") == "Location":
            location_blocked = True
        elif restriction.get("type") == "Zone":
            zone_blocked = True
    return (not location_blocked, zone_blocked)


def collect(region: str, args) -> dict:
    result = {}
    for sku in list_skus(region):
        ok, zoned = usable(sku)
        if not ok:
            continue
        vcpu = capability(sku, "vCPUs")
        mem = capability(sku, "MemoryGB")
        if not args.all_sizes:
            if not (args.min_vcpu <= vcpu <= args.max_vcpu):
                continue
            if mem < args.min_mem:
                continue
        result[sku["name"]] = {"vcpu": vcpu, "mem": mem, "zoned": zoned}
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("regions", nargs="+")
    parser.add_argument("--min-vcpu", type=float, default=2)
    parser.add_argument("--max-vcpu", type=float, default=4)
    parser.add_argument("--min-mem", type=float, default=8)
    parser.add_argument("--all-sizes", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    per_region = {}
    for region in args.regions:
        per_region[region] = collect(region, args)
        print(f"{region}: {len(per_region[region])} usable sizes matching filter",
              file=sys.stderr)

    common = set.intersection(*(set(v) for v in per_region.values()))
    if not common:
        print("\nNo size is available in all of those regions with that filter.",
              file=sys.stderr)
        print("Try --min-mem 4, or widen --max-vcpu.", file=sys.stderr)
        return

    rows = []
    for name in common:
        first = per_region[args.regions[0]][name]
        zoned_in = [r for r in args.regions if per_region[r][name]["zoned"]]
        rows.append({
            "sku": name,
            "vcpu": first["vcpu"],
            "memGB": first["mem"],
            "zoneRestrictedIn": zoned_in,
        })
    rows.sort(key=lambda r: (r["vcpu"], r["memGB"], r["sku"]))

    if args.json:
        print(json.dumps(rows, indent=2))
        return

    print(f"\n{len(rows)} sizes available in all of: {', '.join(args.regions)}\n")
    print(f"{'SKU':<28} {'vCPU':>5} {'MemGB':>7}  notes")
    print("-" * 62)
    for row in rows:
        note = ("no zones in " + ",".join(row["zoneRestrictedIn"])
                if row["zoneRestrictedIn"] else "")
        print(f"{row['sku']:<28} {row['vcpu']:>5.0f} {row['memGB']:>7.1f}  {note}")


if __name__ == "__main__":
    main()
