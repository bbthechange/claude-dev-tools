---
name: preview
description: This skill should be used when the user asks to "preview UI changes", "see how it looks", "take a screenshot", "build and view", "iterate on the UI", "check the simulator", "verify the layout", or when autonomous UI iteration is needed after making SwiftUI code changes. Enables build-navigate-screenshot-iterate workflow without user intervention.
---

# iOS UI Preview

Build, navigate, and screenshot the iOS app for visual verification of UI changes.

## CRITICAL: Chaining Rule

**ALWAYS chain sim.sh commands in ONE Bash call.** Using `&&` or multiple Bash calls triggers approval prompts and breaks autonomous iteration.

```bash
# CORRECT — single call, no approval prompts:
./scripts/sim.sh build go home tap "Settings" wait 1 screenshot

# WRONG — triggers approval for each command:
./scripts/sim.sh build && ./scripts/sim.sh go home && ./scripts/sim.sh screenshot
```

## Iterate-Fix Cycle

Every iteration = exactly 2 tool calls:
1. **Bash**: `./scripts/sim.sh [commands] screenshot`
2. **Read**: `tmp/preview.png`

Analyze screenshot → make code changes → repeat.

## Commands

| Command | Description |
|---------|-------------|
| `build` | Build + install + launch (use after code changes) |
| `install` | Install + launch (skip build, use for quick test) |
| `go <screen>` | Navigate via deep link |
| `screenshot` / `snap` | Save to `tmp/preview.png` |
| `tap <label>` | Tap by accessibility label |
| `tap-xy <x> <y>` | Tap at coordinates |
| `labels` | List all accessibility labels on screen |
| `ui` | Full accessibility tree (JSON) |
| `type <text>` | Type into focused field |
| `swipe <dir>` | Swipe up/down/left/right |
| `wait <secs>` | Pause for animations |
| `reset` | Uninstall + reinstall + launch fresh |

## Navigation Targets

Deep link routes defined in `App/DeepLinkHandler.swift`. Default route: `home`

Add routes as screens are built. Update both `DeepLinkHandler.swift` and the sim.sh header.

## Examples

```bash
# Build and verify home screen
./scripts/sim.sh build screenshot

# Navigate to settings and screenshot
./scripts/sim.sh go home tap "Settings" wait 0.5 screenshot

# Scroll down and screenshot
./scripts/sim.sh swipe up wait 0.3 screenshot

# Type in search field
./scripts/sim.sh tap "Search" type "query" screenshot
```

## Finding Elements

### List Labels (Quick)
```bash
./scripts/sim.sh labels
```

### Full UI Tree (Detailed)
```bash
./scripts/sim.sh ui
```

### When Label Tap Fails

If `tap <label>` doesn't work:
1. Check exact label with `labels` command
2. Watch for special characters (curly quotes, em-dashes)
3. Fall back to coordinates: get frame from `ui` output, calculate center, use `tap-xy`

## Key Labels

Document important accessibility labels as screens are built:

| Screen | Key Labels |
|--------|------------|
| Home | (add as built) |
| Settings | (add as built) |

**Important**: Always add `.accessibilityLabel("Label")` to toolbar buttons. Without it, SwiftUI exposes the SF Symbol name which is hard to tap reliably.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "No simulator found" | Check `xcrun simctl list devices available` |
| "No DerivedData found" | Run `build` first |
| Label tap fails silently | Use `labels` to check exact text, or use `tap-xy` |
| First deep link shows dialog | `reset` auto-accepts it; or manually tap "Open" |
| Build fails | Check xcodebuild output, fix Swift errors |

## Validation Checklist

After taking screenshot, verify:

1. **Correct screen** — Navigation arrived at intended destination
2. **No clipping** — All content fully visible
3. **Layout correct** — Elements positioned as expected
4. **Edge cases** — Consider different content lengths
