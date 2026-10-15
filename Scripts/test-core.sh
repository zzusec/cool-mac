#!/bin/bash
set -euo pipefail

# Run the original Swift Testing suites against the real package sources.
# CLT 27's swiftbuild finds Testing, but needs its existing macro plugin loaded
# explicitly. The native backend does not locate Testing on this toolchain.
# These suites use synthetic snapshots, codec buffers and a monotonic clock;
# this script does not launch the app/helper or access fan hardware.
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
swiftc_path="$(xcrun --find swiftc)"
testing_plugin="$(dirname -- "$swiftc_path")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"

if [[ ! -r "$testing_plugin" ]]; then
    printf 'Error: current Swift toolchain has no readable TestingMacros plugin at %s\n' "$testing_plugin" >&2
    exit 1
fi

printf 'Using TestingMacros: %s\n' "$testing_plugin" >&2
exec xcrun swift test \
    --package-path "$root" \
    --build-system swiftbuild \
    --jobs 2 \
    --disable-xctest \
    --enable-swift-testing \
    -Xswiftc -load-plugin-library \
    -Xswiftc "$testing_plugin" \
    "$@"
