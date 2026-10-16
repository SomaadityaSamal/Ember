#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 ]]; then echo "Usage: $0 [git-ref]" >&2; exit 1; fi
mkdir -p build
benchmark="$(mktemp -d "$PWD/build/grouping-benchmark.XXXXXX")"
for source in HeatModel.swift Preferences.swift; do
    if [[ $# == 1 ]]; then
        git show "$1:Sources/HeatCore/$source" > "$benchmark/$source"
    else
        cp "Sources/HeatCore/$source" "$benchmark/$source"
    fi
done
cp scripts/grouping-benchmark.swift "$benchmark/benchmark.swift"
swiftc -O "$benchmark/HeatModel.swift" "$benchmark/Preferences.swift" "$benchmark/benchmark.swift" -o "$benchmark/grouping"
"$benchmark/grouping"
