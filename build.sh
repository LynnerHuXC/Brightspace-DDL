#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
build_dir=$(mktemp -d /private/tmp/brightspace-build.XXXXXX)
app="$build_dir/Brightspace DDL.app"
mkdir -p "$app/Contents/MacOS" .build/module-cache
mkdir -p "$app/Contents/Resources"
cp -R Extension "$app/Contents/Resources/Extension"
swift -module-cache-path /private/tmp/brightspace-swift-module-cache scripts/make-icon.swift "$build_dir/AppIcon.iconset"
iconutil -c icns "$build_dir/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path /private/tmp/brightspace-swift-module-cache NativeBridge/Identity.swift Sources/ChromeSetup.swift Sources/Core.swift Sources/External.swift Sources/AppMenu.swift Sources/Store.swift Sources/App.swift -o "$app/Contents/MacOS/BrightspaceDDL"
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path /private/tmp/brightspace-swift-module-cache Sources/Core.swift Sources/External.swift NativeBridge/Identity.swift NativeBridge/main.swift -o "$app/Contents/MacOS/DDLBridge"
codesign --force --sign - "$app/Contents/MacOS/DDLBridge"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --identifier local.brightspace.ddl "$app"
codesign --verify --strict "$app"
mkdir -p dist
ditto -c -k --keepParent "$app" dist/BrightspaceDDL.zip
printf '%s\n' "$app" > .build/app-path.txt
printf 'Built and verified: %s\nPackaged: %s/dist/BrightspaceDDL.zip\n' "$app" "$PWD"
