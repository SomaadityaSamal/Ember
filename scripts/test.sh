#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
developer_dir="$(xcode-select -p)"
# The standalone CLT keeps Swift Testing outside the default compiler search path.
if [[ -d "$developer_dir/Library/Developer/Frameworks/Testing.framework" ]]; then
    swift test --build-system native --disable-xctest \
        -Xswiftc -F -Xswiftc "$developer_dir/Library/Developer/Frameworks" \
        -Xswiftc -plugin-path -Xswiftc "$developer_dir/usr/lib/swift/host/plugins/testing" \
        -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/Frameworks"
else
    swift test --build-system native --disable-xctest
fi
mkdir -p build/tests
clang -Wall -Wextra -Werror -I Sources/TelemetryBridge/include Tests/FanHardwareTests/fan_hardware_test.c -framework IOKit -o build/tests/fan-hardware-tests
build/tests/fan-hardware-tests
