#!/bin/bash

APP_NAME="ADBridge.app"
ICON_FILE="AppIcon.icns"
INFO_PLIST_FILE="Info.plist"
BINARY_NAME="adbridge"
SOURCE_FILE="main.swift"

killall "$BINARY_NAME" 2>/dev/null

echo "🔨 Building $APP_NAME ..."
swiftc "$SOURCE_FILE" -o "$BINARY_NAME"

mkdir -p "$APP_NAME/Contents/MacOS"
mkdir -p "$APP_NAME/Contents/Resources"

mv "$BINARY_NAME" "$APP_NAME/Contents/MacOS/$BINARY_NAME"
cp "assets/$ICON_FILE" "$APP_NAME/Contents/Resources/$ICON_FILE"
cp "assets/$INFO_PLIST_FILE" "$APP_NAME/Contents/$INFO_PLIST_FILE"
chmod +x "$APP_NAME/Contents/MacOS/$BINARY_NAME"

# Ad-hoc sign the app (Fixes "won't launch" issues on M1/M2/M3)
codesign --force --deep --sign - "$APP_NAME"

touch "$APP_NAME"
echo "✅ $APP_NAME is ready."