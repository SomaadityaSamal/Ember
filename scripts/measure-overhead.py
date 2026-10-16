#!/usr/bin/env python3
"""Print only aggregate CPU and memory for a chosen Ember PID; no process list."""
import argparse
import re
import statistics
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("pid", type=int)
parser.add_argument("--samples", type=int, default=7)
parser.add_argument("--seconds", type=int, default=5)
args = parser.parse_args()
if args.pid <= 1 or not 2 <= args.samples <= 31 or not 1 <= args.seconds <= 30:
    parser.error("PID > 1; samples 2–31; seconds 1–30")
result = subprocess.run(["/usr/bin/top", "-l", str(args.samples), "-s", str(args.seconds), "-pid", str(args.pid), "-stats", "pid,command,cpu,mem"], capture_output=True, text=True, check=True)
rows = []
for line in result.stdout.splitlines():
    match = re.match(rf"\s*{args.pid}\s+Ember\s+([0-9.]+)\s+(\S+)", line)
    if match: rows.append((float(match[1]), match[2].rstrip("+-")))
rows = rows[1:]  # The first top sample has no measurement interval.
if not rows: raise SystemExit("No Ember sample found for the supplied PID")
cpus = [row[0] for row in rows]
print(f"Ember: {len(rows)} intervals × {args.seconds}s, mean CPU {statistics.mean(cpus):.2f}%, median {statistics.median(cpus):.2f}%, peak {max(cpus):.2f}%, final memory {rows[-1][1]}.")
print("CPU convention: 100% = one logical core. Record panel visibility, polling and animation settings separately.")
