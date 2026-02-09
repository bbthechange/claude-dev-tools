#!/bin/bash
# emu.sh — Emulator automation helper for Claude agents.
# Keeps context usage minimal by combining common multi-step operations.
# Commands are CHAINABLE: ./scripts/emu.sh build install launch screenshot
#
# Usage:
#   ./scripts/emu.sh build          Build debug APK
#   ./scripts/emu.sh install        Install APK to connected device/emulator
#   ./scripts/emu.sh launch         Launch the app
#   ./scripts/emu.sh all            Build + install + launch (full cycle)
#   ./scripts/emu.sh go <screen>    Navigate via deep link
#   ./scripts/emu.sh screenshot     Take screenshot → tmp/preview.png
#   ./scripts/emu.sh tap <label>    Tap element by content description
#   ./scripts/emu.sh back           Press back button
#   ./scripts/emu.sh home           Press home button
#   ./scripts/emu.sh type <text>    Type text into focused field
#   ./scripts/emu.sh logcat         Show app logs (Timber)
#   ./scripts/emu.sh wait <secs>    Sleep for N seconds (for animations)
#
# Screens for "go": home, settings (add project-specific routes as built)

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_NAME="{{PACKAGE_NAME}}"
SCHEME="{{PROJECT_NAME_LOWERCASE}}"
SCREENSHOT_PATH="$PROJECT_DIR/tmp/preview.png"

mkdir -p "$PROJECT_DIR/tmp"

# Wait for device to be ready
_wait_device() {
    adb wait-for-device
    sleep 1
}

cmd_build() {
    echo "==> Building APK..."
    cd "$PROJECT_DIR"
    ./gradlew assembleDebug --quiet
    echo "==> Build complete."
}

cmd_install() {
    echo "==> Installing APK..."
    cd "$PROJECT_DIR"
    ./gradlew installDebug --quiet
    echo "==> Installed."
}

cmd_launch() {
    echo "==> Launching app..."
    _wait_device
    adb shell am start -n "$PACKAGE_NAME/.MainActivity"
    sleep 1
    echo "==> Launched."
}

cmd_all() {
    cmd_build
    cmd_install
    cmd_launch
}

cmd_go() {
    local screen="${1:?Usage: emu.sh go <screen>}"
    echo "==> Opening deep link: $SCHEME://$screen"
    _wait_device
    adb shell am start -W -a android.intent.action.VIEW -d "$SCHEME://$screen" "$PACKAGE_NAME"
    sleep 0.5
}

cmd_screenshot() {
    _wait_device
    adb exec-out screencap -p > "$SCREENSHOT_PATH"
    echo "$SCREENSHOT_PATH"
}

cmd_tap() {
    local label="${1:?Usage: emu.sh tap <label>}"
    echo "==> Tapping: $label"
    _wait_device
    # Use input tap with coordinates from uiautomator dump
    # This is a simplified version - for complex taps, use content description matching
    adb shell "input tap \$(uiautomator dump /dev/tty 2>/dev/null | grep -o 'content-desc=\"$label\"[^>]*bounds=\"\\[[0-9]*,[0-9]*\\]\\[[0-9]*,[0-9]*\\]\"' | head -1 | sed 's/.*\\[\\([0-9]*\\),\\([0-9]*\\)\\]\\[\\([0-9]*\\),\\([0-9]*\\)\\].*/echo \$(( (\\1 + \\3) \/ 2 )) \$(( (\\2 + \\4) \/ 2 ))/' | bash)" 2>/dev/null || {
        echo "Warning: Could not find element with content-desc '$label', trying text match..."
        adb shell "input tap \$(uiautomator dump /dev/tty 2>/dev/null | grep -o 'text=\"$label\"[^>]*bounds=\"\\[[0-9]*,[0-9]*\\]\\[[0-9]*,[0-9]*\\]\"' | head -1 | sed 's/.*\\[\\([0-9]*\\),\\([0-9]*\\)\\]\\[\\([0-9]*\\),\\([0-9]*\\)\\].*/echo \$(( (\\1 + \\3) \/ 2 )) \$(( (\\2 + \\4) \/ 2 ))/' | bash)" 2>/dev/null || echo "Could not tap element"
    }
    sleep 0.3
}

cmd_tap_xy() {
    local x="${1:?Usage: emu.sh tap-xy <x> <y>}"
    local y="${2:?Usage: emu.sh tap-xy <x> <y>}"
    _wait_device
    adb shell input tap "$x" "$y"
    sleep 0.3
}

cmd_back() {
    _wait_device
    adb shell input keyevent KEYCODE_BACK
    sleep 0.3
}

cmd_home() {
    _wait_device
    adb shell input keyevent KEYCODE_HOME
    sleep 0.3
}

cmd_type() {
    local text="${1:?Usage: emu.sh type <text>}"
    _wait_device
    # Replace spaces with %s for adb input text
    adb shell input text "${text// /%s}"
    sleep 0.3
}

cmd_logcat() {
    _wait_device
    adb logcat -s "$PACKAGE_NAME:D" "*:E" | head -100
}

cmd_labels() {
    echo "==> Dumping UI hierarchy..."
    _wait_device
    adb shell uiautomator dump /dev/tty 2>/dev/null | grep -oE 'content-desc="[^"]*"' | sed 's/content-desc="//;s/"$//' | sort -u
}

cmd_ui() {
    _wait_device
    adb shell uiautomator dump /dev/tty 2>/dev/null
}

# Dispatch — supports chaining: ./scripts/emu.sh build install launch go settings screenshot
if [ $# -eq 0 ]; then
    echo "Usage: emu.sh <cmd> [args] [cmd] [args] ..."
    echo ""
    echo "Commands (chainable in one call):"
    echo "  build              Build debug APK"
    echo "  install            Install APK"
    echo "  launch             Launch app"
    echo "  all                Build + install + launch"
    echo "  go <screen>        Navigate via deep link"
    echo "  screenshot / snap  Save screenshot to tmp/preview.png"
    echo "  tap <label>        Tap by content description"
    echo "  tap-xy <x> <y>     Tap at coordinates"
    echo "  labels             List content descriptions on screen"
    echo "  ui                 Full UI hierarchy (XML)"
    echo "  back               Press back button"
    echo "  home               Press home button"
    echo "  type <text>        Type text"
    echo "  wait <secs>        Sleep for N seconds"
    echo "  logcat             Show app logs"
    echo ""
    echo "Example: emu.sh all go settings tap \"Dark Mode\" screenshot"
    exit 0
fi

args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
    cmd="${args[$i]}"
    case "$cmd" in
        build)      cmd_build ;;
        install)    cmd_install ;;
        launch)     cmd_launch ;;
        all)        cmd_all ;;
        go)         i=$((i+1)); cmd_go "${args[$i]}" ;;
        screenshot|snap) cmd_screenshot ;;
        tap)        i=$((i+1)); cmd_tap "${args[$i]}" ;;
        tap-xy)     i=$((i+1)); x="${args[$i]}"; i=$((i+1)); cmd_tap_xy "$x" "${args[$i]}" ;;
        labels)     cmd_labels ;;
        ui)         cmd_ui ;;
        back)       cmd_back ;;
        home)       cmd_home ;;
        type)       i=$((i+1)); cmd_type "${args[$i]}" ;;
        wait)       i=$((i+1)); sleep "${args[$i]}" ;;
        logcat)     cmd_logcat ;;
        *)          echo "Unknown command: $cmd"; exit 1 ;;
    esac
    i=$((i+1))
done
