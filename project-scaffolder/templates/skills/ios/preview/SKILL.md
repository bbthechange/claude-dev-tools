---
name: preview
description: This skill should be used when the user asks to "preview UI changes", "see how it looks", "take a screenshot", "build and view", "iterate on the UI", "check the simulator", "verify the layout", or when autonomous UI iteration is needed after making SwiftUI code changes. Enables build-navigate-screenshot-iterate workflow without user intervention.
---

# iOS UI Preview

Build, navigate, and screenshot the iOS app for visual verification of UI changes.

## Setup (First Time)

### 1. Find Your Simulator UDID

```bash
xcrun simctl list devices available | grep "iPhone" | head -10
```

Pick one and note the UDID in parentheses, e.g., `(A1B2C3D4-E5F6-...)`.

### 2. Install Required Tools

```bash
brew tap ldomaradzki/xcsift && brew install xcsift
brew install cameroncooke/axe/axe
```

## Quick Reference

| Task | Command |
|------|---------|
| Build | `xcodebuild -project {{PROJECT_NAME}}.xcodeproj -scheme {{PROJECT_NAME}} -destination "platform=iOS Simulator,id={{UDID}}" build 2>&1 \| xcsift` |
| Find DerivedData | `ls ~/Library/Developer/Xcode/DerivedData/ \| grep {{PROJECT_NAME}}` |
| Install | `xcrun simctl install {{UDID}} ~/Library/Developer/Xcode/DerivedData/{{PROJECT_NAME}}-{{HASH}}/Build/Products/Debug-iphonesimulator/{{PROJECT_NAME}}.app` |
| Boot simulator | `xcrun simctl boot {{UDID}}` |
| Screenshot | `xcrun simctl io {{UDID}} screenshot /tmp/preview.png` |
| View | Read tool on `/tmp/preview.png` |
| Get UI tree | `axe describe-ui --udid {{UDID}}` |
| Tap coordinates | `axe tap -x X -y Y --udid {{UDID}}` |
| Tap label | `axe tap --label "Label" --udid {{UDID}}` |
| Swipe up | `axe swipe --start-x 200 --start-y 600 --end-x 200 --end-y 300 --udid {{UDID}}` |

**Replace `{{UDID}}` with your simulator's actual UDID.**

## Workflow

### Step 1: Build (only when code changed)

```bash
xcodebuild -project {{PROJECT_NAME}}.xcodeproj -scheme {{PROJECT_NAME}} -destination "platform=iOS Simulator,id={{UDID}}" build 2>&1 | xcsift
```

### Step 2: Install (get fresh DerivedData path first)

```bash
ls ~/Library/Developer/Xcode/DerivedData/ | grep {{PROJECT_NAME}}
# Use output to construct path:
xcrun simctl install {{UDID}} ~/Library/Developer/Xcode/DerivedData/{{PROJECT_NAME}}-{{HASH}}/Build/Products/Debug-iphonesimulator/{{PROJECT_NAME}}.app
```

### Step 3: Navigate Using Accessibility Tree

```bash
# Get all UI elements
axe describe-ui --udid {{UDID}}

# Get just labels
axe describe-ui --udid {{UDID}} 2>&1 | grep -E "AXLabel" | head -20
```

### Step 4: Screenshot and View

```bash
xcrun simctl io {{UDID}} screenshot /tmp/preview.png
```

Then use Read tool on `/tmp/preview.png`.

## Finding and Tapping Elements

### By Label (when accessible)

```bash
axe tap --label "Settings" --udid {{UDID}}
axe tap --label "Back" --udid {{UDID}}
```

### By Coordinates (when label fails)

Get frame from accessibility tree:
```bash
axe describe-ui --udid {{UDID}} 2>&1 | grep "TargetText" -B 5
```

From frame `{"x": 16, "y": 243, "width": 267, "height": 100}`:
- Center X = 16 + 267/2 = 149.5
- Center Y = 243 + 100/2 = 293

```bash
axe tap -x 150 -y 293 --udid {{UDID}}
```

### Scrolling

```bash
# Scroll down
axe swipe --start-x 200 --start-y 600 --end-x 200 --end-y 300 --udid {{UDID}}

# Scroll up
axe swipe --start-x 200 --start-y 300 --end-x 200 --end-y 600 --udid {{UDID}}
```

## Known Issues

| Issue | Solution |
|-------|----------|
| Special chars in labels (curly apostrophes) | Use coordinates instead of `--label` |
| Nav bar buttons missing from accessibility | Use coordinates |
| `$(find ...)` subshells fail | Run commands separately |
| Simulator not booted | `xcrun simctl boot {{UDID}}` |
| Label tap fails silently | Check `axe describe-ui` output, use coordinates |

## Validation Checklist

After taking screenshot, verify:

1. **Correct screen** - Navigation arrived at intended destination
2. **No clipping** - All content fully visible
3. **Layout correct** - Elements positioned as expected
4. **Edge cases** - Consider different content lengths
