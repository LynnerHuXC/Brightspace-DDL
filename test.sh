#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
swiftc -module-cache-path /private/tmp/brightspace-swift-module-cache Sources/Core.swift Sources/External.swift Sources/AppMenu.swift Tests/main.swift -o .build/core-tests
.build/core-tests "$@"
swiftc -module-cache-path /private/tmp/brightspace-swift-module-cache NativeBridge/Identity.swift Sources/ChromeSetup.swift Tests/chrome-setup.swift -o .build/chrome-setup-tests
.build/chrome-setup-tests
