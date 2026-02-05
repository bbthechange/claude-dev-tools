#!/usr/bin/env bash
# sim.sh — One-stop simulator helper for Claude agents.
# Keeps context usage minimal by combining common multi-step operations.
# Commands are CHAINABLE: ./scripts/sim.sh build go home tap "Settings" screenshot
#
# Usage:
#   ./scripts/sim.sh build          Build + install + launch (full cycle)
#   ./scripts/sim.sh install        Install + launch (skip build)
#   ./scripts/sim.sh go <screen>    Navigate to a screen via deep link
#   ./scripts/sim.sh screenshot     Take screenshot → tmp/preview.png
#   ./scripts/sim.sh tap <label>    Tap element by accessibility label
#   ./scripts/sim.sh tap-xy <x> <y> Tap at coordinates
#   ./scripts/sim.sh labels         Print all accessibility labels on screen
#   ./scripts/sim.sh ui             Full accessibility tree (JSON)
#   ./scripts/sim.sh type <text>    Type text into focused field
#   ./scripts/sim.sh swipe <dir>    Swipe up/down/left/right
#   ./scripts/sim.sh wait <secs>    Sleep for N seconds (for animations)
#   ./scripts/sim.sh reset          Terminate app + erase state + relaunch
#
# Screens for "go": home (add project-specific routes as they're built)
#
# Environment:
#   SIM_UDID    Override simulator UDID (default: first available iPhone)

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_NAME="{{PROJECT_NAME}}"
BUNDLE_ID="{{BUNDLE_PREFIX}}.{{PROJECT_NAME_LOWERCASE}}"
URL_SCHEME="{{PROJECT_NAME_LOWERCASE}}"
SCREENSHOT_PATH="$PROJECT_DIR/tmp/preview.png"

# Auto-detect simulator UDID if not set
if [ -z "${SIM_UDID:-}" ]; then
    UDID=$(xcrun simctl list devices available | grep "iPhone" | head -1 | sed -E 's/.*\(([A-F0-9-]+)\).*/\1/')
    if [ -z "$UDID" ]; then
        echo "Error: No iPhone simulator found. Install one via Xcode."
        exit 1
    fi
else
    UDID="$SIM_UDID"
fi

mkdir -p "$PROJECT_DIR/tmp"

# Ensure simulator is booted
_boot() {
    xcrun simctl boot "$UDID" 2>/dev/null || true
}

# Find the built .app path
_app_path() {
    local dd
    dd=$(ls ~/Library/Developer/Xcode/DerivedData/ | grep "$PROJECT_NAME" | head -1)
    if [ -z "$dd" ]; then
        echo "Error: No DerivedData found for $PROJECT_NAME. Run 'build' first." >&2
        exit 1
    fi
    echo "$HOME/Library/Developer/Xcode/DerivedData/$dd/Build/Products/Debug-iphonesimulator/$PROJECT_NAME.app"
}

cmd_build() {
    echo "==> Building..."
    cd "$PROJECT_DIR"
    xcodebuild -project "$PROJECT_NAME.xcodeproj" \
        -scheme "$PROJECT_NAME" \
        -destination "platform=iOS Simulator,id=$UDID" \
        build 2>&1 | xcsift
    echo "==> Installing..."
    _boot
    xcrun simctl install "$UDID" "$(_app_path)"
    echo "==> Launching..."
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID"
    sleep 1
    cmd_accept_deeplinks
    echo "==> Ready."
}

cmd_install() {
    _boot
    xcrun simctl install "$UDID" "$(_app_path)"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID"
    sleep 1
    echo "==> Installed and launched."
}

cmd_go() {
    local screen="${1:?Usage: sim.sh go <screen>}"
    xcrun simctl openurl "$UDID" "$URL_SCHEME://$screen"
    sleep 0.5
}

cmd_screenshot() {
    xcrun simctl io "$UDID" screenshot "$SCREENSHOT_PATH" 2>/dev/null
    echo "$SCREENSHOT_PATH"
}

cmd_tap() {
    local label="${1:?Usage: sim.sh tap <label>}"
    axe tap --label "$label" --udid "$UDID" 2>&1
    sleep 0.3
}

cmd_tap_xy() {
    local x="${1:?Usage: sim.sh tap-xy <x> <y>}"
    local y="${2:?Usage: sim.sh tap-xy <x> <y>}"
    axe tap -x "$x" -y "$y" --udid "$UDID" 2>&1
    sleep 0.3
}

cmd_labels() {
    axe describe-ui --udid "$UDID" 2>&1 | sed -n 's/.*"AXLabel" *: *"\([^"]*\)".*/\1/p' | sort -u
}

cmd_ui() {
    axe describe-ui --udid "$UDID" 2>&1
}

cmd_type() {
    local text="${1:?Usage: sim.sh type <text>}"
    axe type "$text" --udid "$UDID" 2>&1
}

cmd_swipe() {
    local dir="${1:?Usage: sim.sh swipe up|down|left|right}"
    case "$dir" in
        up)    axe swipe --start-x 200 --start-y 600 --end-x 200 --end-y 300 --udid "$UDID" 2>&1 ;;
        down)  axe swipe --start-x 200 --start-y 300 --end-x 200 --end-y 600 --udid "$UDID" 2>&1 ;;
        left)  axe swipe --start-x 350 --start-y 400 --end-x 50  --end-y 400 --udid "$UDID" 2>&1 ;;
        right) axe swipe --start-x 50  --start-y 400 --end-x 350 --end-y 400 --udid "$UDID" 2>&1 ;;
        *) echo "Unknown direction: $dir"; exit 1 ;;
    esac
    sleep 0.3
}

cmd_reset() {
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl install "$UDID" "$(_app_path)"
    xcrun simctl launch "$UDID" "$BUNDLE_ID"
    sleep 1
    cmd_accept_deeplinks
    echo "==> Reset and relaunched."
}

cmd_accept_deeplinks() {
    echo "==> Triggering deep link to dismiss first-time dialog..."
    xcrun simctl openurl "$UDID" "$URL_SCHEME://home" 2>/dev/null || true
    sleep 1
    # Try to tap "Open" button if dialog appeared
    axe tap --label "Open" --udid "$UDID" 2>/dev/null || true
    sleep 0.5
    echo "==> Deep link dialog accepted (if it appeared)."
}

# Dispatch — supports chaining: ./scripts/sim.sh go browse tap "Save" screenshot
if [ $# -eq 0 ]; then
    echo "Usage: sim.sh <cmd> [args] [cmd] [args] ..."
    echo ""
    echo "Commands (chainable in one call):"
    echo "  build              Build + install + launch"
    echo "  install            Install + launch (skip build)"
    echo "  go <screen>        Navigate via deep link (add routes to DeepLinkHandler.swift)"
    echo "  screenshot / snap  Save screenshot to tmp/preview.png"
    echo "  tap <label>        Tap by accessibility label"
    echo "  tap-xy <x> <y>     Tap at coordinates"
    echo "  labels             List all accessibility labels on screen"
    echo "  ui                 Full accessibility tree (JSON)"
    echo "  type <text>        Type text into focused field"
    echo "  swipe <dir>        Swipe: up|down|left|right"
    echo "  wait <secs>        Sleep for N seconds"
    echo "  reset              Uninstall, reinstall, launch fresh"
    echo ""
    echo "Example: sim.sh build go home tap \"Settings\" screenshot"
    exit 0
fi

args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
    cmd="${args[$i]}"
    case "$cmd" in
        build)      cmd_build ;;
        install)    cmd_install ;;
        go)         i=$((i+1)); cmd_go "${args[$i]}" ;;
        screenshot|snap) cmd_screenshot ;;
        tap)        i=$((i+1)); cmd_tap "${args[$i]}" ;;
        tap-xy)     i=$((i+1)); x="${args[$i]}"; i=$((i+1)); cmd_tap_xy "$x" "${args[$i]}" ;;
        labels)     cmd_labels ;;
        ui)         cmd_ui ;;
        type)       i=$((i+1)); cmd_type "${args[$i]}" ;;
        swipe)      i=$((i+1)); cmd_swipe "${args[$i]}" ;;
        wait)       i=$((i+1)); sleep "${args[$i]}" ;;
        reset)      cmd_reset ;;
        accept-deeplinks) cmd_accept_deeplinks ;;
        *)          echo "Unknown command: $cmd"; exit 1 ;;
    esac
    i=$((i+1))
done
