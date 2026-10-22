#!/bin/bash
#
# Build SysBar.app — a signed, ready-to-run Apple Silicon menu bar app bundle.
#
# Usage: ./build.sh [--install]
#   --install   Copies the built app to ~/Applications/ after building
#
# Exit status 3 means the release executable or app bundle exceeded its size
# budget (EXECUTABLE_SIZE_BUDGET_BYTES / BUNDLE_SIZE_BUDGET_BYTES below).
#

set -euo pipefail

APP_NAME="SysBar"
BUNDLE_ID="io.github.swifai.sysbar"
VERSION="1.2.1"
BUILD_NUMBER="4"

# Release size budgets (docs/adr/ADR-018). This is the one place they are set.
# Exact bytes, not disk blocks: the executable is `stat -f %z`, and the bundle is
# the sum of `stat -f %z` over every regular file in the signed .app. Exceeding
# either budget exits with status 3, before --install can copy anything.
# Baseline 2026-10-16 (Apple Swift 6.4, arm64, stripped executable): executable
# 1659984 bytes, bundle 2268247 bytes. Before stripping (2026-09-29) the executable
# was 2965552 bytes and varied by a few KiB with the checkout path (debug map).
# The executable budget stays below a debug build (~4.75 MiB) so that packaging
# one fails. Raise a budget only deliberately, in its own commit: rebuild, take
# the new sizes from this script's output, explain the growth in the commit
# message, and keep roughly 40% headroom.
EXECUTABLE_SIZE_BUDGET_BYTES=4194304   # 4 MiB
BUNDLE_SIZE_BUDGET_BYTES=5242880       # 5 MiB

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_DIR="${SCRIPT_DIR}/build"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_PATH}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"

echo "→ Cleaning previous build"
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "→ Compiling Swift (release, -Osize, arm64)"
swift build -c release --arch arm64

# Ask SwiftPM for this toolchain's output directory. Newer Xcode-backed builds
# use Products/Release, while earlier toolchains use the target triple.
SWIFTPM_BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
BINARY_SRC="${SWIFTPM_BIN_DIR}/${APP_NAME}"

echo "→ Copying binary to ${MACOS_DIR}"
cp "$BINARY_SRC" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

# Ship like an Xcode Release build: debug info goes to a dSYM beside the app
# (for symbolicating crash reports), and the executable loses its symbol table,
# which is mostly long mangled SwiftUI names (about two thirds of the file).
# Swift's runtime metadata lives in its own sections and is not affected.
echo "→ Writing dSYM and stripping symbols"
dsymutil "${MACOS_DIR}/${APP_NAME}" -o "${BUILD_DIR}/${APP_NAME}.app.dSYM" 2>/dev/null \
    || echo "  (no dSYM written; continuing)"
strip "${MACOS_DIR}/${APP_NAME}"

RESOURCE_BUNDLE_NAME="SysBar_SysBar.bundle"
RESOURCE_BUNDLE_SRC="${SWIFTPM_BIN_DIR}/${RESOURCE_BUNDLE_NAME}"
if [ ! -d "$RESOURCE_BUNDLE_SRC" ]; then
    echo "Resource bundle not found: ${RESOURCE_BUNDLE_NAME}" >&2
    exit 1
fi

# Keep resources in the standard sealed location. The nested SwiftPM bundle is
# retained for package lookups, while its English table is also installed into
# the main app bundle for SwiftUI's default localized-string resolution.
RESOURCE_BUNDLE_DEST="${RESOURCES_DIR}/${RESOURCE_BUNDLE_NAME}"
echo "→ Copying localization resources"
cp -R "$RESOURCE_BUNDLE_SRC" "$RESOURCE_BUNDLE_DEST"
RESOURCE_TABLES_DIR="$RESOURCE_BUNDLE_SRC"
if [ -d "${RESOURCE_BUNDLE_SRC}/Contents/Resources" ]; then
    RESOURCE_TABLES_DIR="${RESOURCE_BUNDLE_SRC}/Contents/Resources"
fi
if [ -d "${RESOURCE_TABLES_DIR}/en.lproj" ]; then
    cp -R "${RESOURCE_TABLES_DIR}/en.lproj" "$RESOURCES_DIR/"
fi
if [ -f "${RESOURCE_TABLES_DIR}/Localizable.xcstrings" ]; then
    cp "${RESOURCE_TABLES_DIR}/Localizable.xcstrings" "$RESOURCES_DIR/"
fi

echo "→ Generating app icon"
ICON_WORK="${BUILD_DIR}/iconwork"
rm -rf "$ICON_WORK"
mkdir -p "$ICON_WORK"
swift tools/makeicon.swift "${ICON_WORK}/icon-1024.png" >/dev/null

ICONSET="${ICON_WORK}/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -z 16   16   "${ICON_WORK}/icon-1024.png" --out "${ICONSET}/icon_16x16.png"      >/dev/null
sips -z 32   32   "${ICON_WORK}/icon-1024.png" --out "${ICONSET}/icon_16x16@2x.png"   >/dev/null
sips -z 32   32   "${ICON_WORK}/icon-1024.png" --out "${ICONSET}/icon_32x32.png"      >/dev/null
sips -z 64   64   "${ICON_WORK}/icon-1024.png" --out "${ICONSET}/icon_32x32@2x.png"   >/dev/null
sips -z 128  128  "${ICON_WORK}/icon-1024.png" --out "${ICONSET}/icon_128x128.png"    >/dev/null
sips -z 256  256  "${ICON_WORK}/icon-1024.png" --out "${ICONSET}/icon_128x128@2x.png" >/dev/null
sips -z 256  256  "${ICON_WORK}/icon-1024.png" --out "${ICONSET}/icon_256x256.png"    >/dev/null
sips -z 512  512  "${ICON_WORK}/icon-1024.png" --out "${ICONSET}/icon_256x256@2x.png" >/dev/null
sips -z 512  512  "${ICON_WORK}/icon-1024.png" --out "${ICONSET}/icon_512x512.png"    >/dev/null
cp "${ICON_WORK}/icon-1024.png" "${ICONSET}/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "${RESOURCES_DIR}/AppIcon.icns"

echo "→ Writing Info.plist"
cat > "${CONTENTS}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>SysBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 SwifAI</string>
</dict>
</plist>
EOF

echo "→ Writing PkgInfo"
printf "APPL????" > "${CONTENTS}/PkgInfo"

SIGN_IDENTITY="${SYSBAR_SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "→ Ad-hoc code signing"
    codesign --force --sign - "$APP_PATH" >/dev/null
else
    echo "→ Developer ID signing"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_PATH"
fi
codesign --verify --strict "$APP_PATH"

echo "→ Checking release size budgets"
EXECUTABLE_BYTES="$(/usr/bin/stat -f %z "${MACOS_DIR}/${APP_NAME}")"
BUNDLE_BYTES="$(/usr/bin/find "$APP_PATH" -type f -exec /usr/bin/stat -f %z {} + \
    | /usr/bin/awk '{ total += $1 } END { printf "%.0f\n", total }')"

format_mib() {
    /usr/bin/awk -v bytes="$1" 'BEGIN { printf "%.2f MiB", bytes / 1048576 }'
}

size_budget_exceeded=0
check_size_budget() {
    local artifact="$1"
    local actual_bytes="$2"
    local budget_bytes="$3"
    case "$actual_bytes" in
        ''|*[!0-9]*)
            echo "✗ Could not measure the size of the ${artifact}: '${actual_bytes}'" >&2
            exit 1
            ;;
    esac
    if (( actual_bytes > budget_bytes )); then
        echo "✗ Size budget exceeded: ${artifact} is ${actual_bytes} bytes" \
            "($(format_mib "$actual_bytes")), over its ${budget_bytes}-byte" \
            "($(format_mib "$budget_bytes")) budget by $(( actual_bytes - budget_bytes )) bytes." >&2
        size_budget_exceeded=1
    fi
}
check_size_budget "executable ${MACOS_DIR}/${APP_NAME}" \
    "$EXECUTABLE_BYTES" "$EXECUTABLE_SIZE_BUDGET_BYTES"
check_size_budget "app bundle ${APP_PATH}" "$BUNDLE_BYTES" "$BUNDLE_SIZE_BUDGET_BYTES"
if (( size_budget_exceeded > 0 )); then
    echo "  Shrink the artifact, or raise its budget deliberately as described next to" >&2
    echo "  EXECUTABLE_SIZE_BUDGET_BYTES / BUNDLE_SIZE_BUDGET_BYTES at the top of build.sh." >&2
    exit 3
fi

echo ""
echo "✓ Built ${APP_PATH}"
echo "  Binary size:  ${EXECUTABLE_BYTES} bytes ($(format_mib "$EXECUTABLE_BYTES"))" \
    "of ${EXECUTABLE_SIZE_BUDGET_BYTES}-byte budget ($(format_mib "$EXECUTABLE_SIZE_BUDGET_BYTES"))"
echo "  Bundle size:  ${BUNDLE_BYTES} bytes ($(format_mib "$BUNDLE_BYTES"))" \
    "of ${BUNDLE_SIZE_BUDGET_BYTES}-byte budget ($(format_mib "$BUNDLE_SIZE_BUDGET_BYTES"))"
echo ""

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications/${APP_NAME}.app"
    INSTALLED_EXECUTABLE="${DEST}/Contents/MacOS/${APP_NAME}"
    mkdir -p "$HOME/Applications"

    executable_for_pid() {
        /usr/sbin/lsof -a -p "$1" -d txt -Fn 2>/dev/null \
            | /usr/bin/sed -n 's/^n//p' \
            | /usr/bin/head -n 1
    }

    wait_for_installed_exit() {
        local process_id="$1"
        local attempt
        local running_command
        for attempt in {1..30}; do
            running_command="$(executable_for_pid "$process_id" || true)"
            if [[ "$running_command" != "$INSTALLED_EXECUTABLE" ]]; then
                return 0
            fi
            sleep 0.1
        done
        echo "Installed SysBar did not exit after SIGTERM (PID ${process_id})" >&2
        return 1
    }

    # Stop only a process whose executable path is the exact installed binary.
    installed_pids=()
    while IFS= read -r process_id; do
        [[ -n "$process_id" ]] || continue
        running_command="$(executable_for_pid "$process_id" || true)"
        if [[ "$running_command" == "$INSTALLED_EXECUTABLE" ]]; then
            kill -TERM "$process_id"
            installed_pids+=("$process_id")
        fi
    done < <(pgrep -x "$APP_NAME" 2>/dev/null || true)
    # macOS ships Bash 3.2, where expanding an empty array under `set -u`
    # raises an unbound-variable error. Guard the expansion explicitly.
    if (( ${#installed_pids[@]} > 0 )); then
        for process_id in "${installed_pids[@]}"; do
            wait_for_installed_exit "$process_id"
        done
    fi

    echo "→ Installing to $DEST"
    rm -rf "$DEST"
    cp -R "$APP_PATH" "$DEST"

    echo "→ Launching"
    open "$DEST"

    echo ""
    echo "✓ SysBar is running from $DEST"
    echo ""
    echo "To auto-start at login:"
    echo "  System Settings → General → Login Items → + → ${DEST/$HOME/~}"
else
    echo "Next steps:"
    echo "  • Run now:        open ${APP_PATH}"
    echo "  • Install:        ./build.sh --install"
fi
