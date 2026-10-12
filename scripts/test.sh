#!/bin/bash
# Runs the unit tests. The Command Line Tools toolchain keeps the Swift Testing
# macro plugin in plugins/testing/, which swift-build doesn't always search,
# so pass that folder explicitly. Extra args go to `swift test` (e.g. --filter X).
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGINS="$(dirname "$(xcrun -f swift)")/../lib/swift/host/plugins/testing"
exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
