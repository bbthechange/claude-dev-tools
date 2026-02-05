# iOS Project Setup

Step-by-step instructions for creating a new iOS project from scratch. All steps are CLI-executable — no Xcode GUI interaction required.

This reference is used by the init-project skill when an iOS project needs to be created. Only run this when no existing project is detected (no `project.yml`, `*.xcodeproj`, or Swift source files).

Architecture and development patterns are covered separately in `IOS_APP_ARCHITECTURE_GUIDE.md`, not here.

---

## The Stack

| Layer | Choice |
|-------|--------|
| UI | SwiftUI |
| Min iOS | 17.0 |
| Project generation | XcodeGen |
| Dependencies | Swift Package Manager (via `project.yml`) |
| Networking | URLSession + async/await |
| Persistence | SwiftData (default) or GRDB (if performance-critical) |
| Unit testing | Swift Testing framework |
| UI testing | XCTest |
| Linting | SwiftLint + SwiftFormat (via Mint) |

---

## Prerequisites

Check and install if missing:

```bash
# XcodeGen — generates .xcodeproj from YAML
brew list xcodegen &>/dev/null || brew install xcodegen

# Mint — pins CLI tool versions (for SwiftLint, SwiftFormat)
brew list mint &>/dev/null || brew install mint

# xcsift — filters xcodebuild output for readability
brew list xcsift &>/dev/null || (brew tap ldomaradzki/xcsift && brew install xcsift)

# axe — accessibility automation for simulators
brew list axe &>/dev/null || brew install cameroncooke/axe/axe
```

---

## Setup Procedure

Replace these placeholders throughout:
- `{{PROJECT_NAME}}` — the actual app name in PascalCase (e.g., `MyApp`)
- `{{BUNDLE_PREFIX}}` — the bundle ID prefix (e.g., `com.yourcompany`)
- `{{project_name_lowercased}}` — the project name lowercased for bundle identifiers (e.g., `MyApp` → `myapp`)

### Step 1: Create the directory structure

```bash
# Source directories
mkdir -p {{PROJECT_NAME}}/App
mkdir -p {{PROJECT_NAME}}/Features
mkdir -p {{PROJECT_NAME}}/Models
mkdir -p {{PROJECT_NAME}}/Services
mkdir -p {{PROJECT_NAME}}/Extensions
mkdir -p {{PROJECT_NAME}}/Components
mkdir -p {{PROJECT_NAME}}/Resources/Assets.xcassets/AppIcon.appiconset
mkdir -p {{PROJECT_NAME}}/Resources/Assets.xcassets/AccentColor.colorset

# Test directory
mkdir -p {{PROJECT_NAME}}Tests

# Scripts directory (for sim.sh)
mkdir -p scripts

# Temp directory for screenshots (gitignored)
mkdir -p tmp
```

### Step 2: Create starter source files

**App entry point** — `{{PROJECT_NAME}}/App/{{PROJECT_NAME}}App.swift`:
```swift
import SwiftUI

@main
struct {{PROJECT_NAME}}App: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

**Root view with deep link support** — `{{PROJECT_NAME}}/App/ContentView.swift`:
```swift
import SwiftUI

struct ContentView: View {
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Text("Hello, World!")
                .navigationTitle("{{PROJECT_NAME}}")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
        }
        .sheet(isPresented: $showSettings) {
            Text("Settings")
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard let route = DeepLinkRoute(url: url) else { return }
        // Dismiss any sheets first
        showSettings = false
        switch route {
        case .home:
            break // Already on home
        // Add cases as screens are built:
        // case .settings:
        //     DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        //         showSettings = true
        //     }
        }
    }
}

#Preview {
    ContentView()
}
```

**Deep link handler** — `{{PROJECT_NAME}}/App/DeepLinkHandler.swift`:

Copy from plugin template and replace placeholders:
```bash
cp ${CLAUDE_PLUGIN_ROOT}/templates/deeplink/DeepLinkHandler.swift {{PROJECT_NAME}}/App/
# Replace {{PROJECT_NAME_LOWERCASE}} with actual value in the file
```

The file defines a `DeepLinkRoute` enum that parses URLs like `{{PROJECT_NAME_LOWERCASE}}://home`. Add routes as screens are built.

**Test file** — `{{PROJECT_NAME}}Tests/{{PROJECT_NAME}}Tests.swift`:
```swift
import Testing

@Suite("{{PROJECT_NAME}} Tests")
struct {{PROJECT_NAME}}Tests {

    @Test("example test")
    func example() {
        #expect(true)
    }
}
```

### Step 3: Create asset catalogs

**`{{PROJECT_NAME}}/Resources/Assets.xcassets/Contents.json`**:
```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

**`{{PROJECT_NAME}}/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`**:
```json
{
  "colors" : [
    {
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

**`{{PROJECT_NAME}}/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`**:
```json
{
  "images" : [
    {
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

### Step 3.5: Create Info.plist

Create a minimal Info.plist with encryption export compliance and URL scheme for deep links:

Copy from plugin template and replace placeholders:
```bash
cp ${CLAUDE_PLUGIN_ROOT}/templates/info-plist/ios-Info.plist {{PROJECT_NAME}}/Info.plist
# Replace {{PROJECT_NAME_LOWERCASE}} with actual value in the file
```

This sets:
- `ITSAppUsesNonExemptEncryption: NO` — declares app uses no custom encryption (HTTPS/TLS is exempt)
- `CFBundleURLTypes` — registers `{{PROJECT_NAME_LOWERCASE}}://` URL scheme for deep links

### Step 4: Create `project.yml`

XcodeGen spec defining the Xcode project. The `info.path` tells XcodeGen to use the custom Info.plist (merged with generated INFOPLIST_KEY settings at build time).

Use the lowercased project name for the bundle identifier suffix (e.g., `MyApp` → `com.yourcompany.myapp`).

```yaml
name: {{PROJECT_NAME}}
options:
  bundleIdPrefix: {{BUNDLE_PREFIX}}
  deploymentTarget:
    iOS: "17.0"
  xcodeVersion: "16.0"
  createIntermediateGroups: true
  generateEmptyDirectories: true

settings:
  base:
    SWIFT_VERSION: "6.0"
    IPHONEOS_DEPLOYMENT_TARGET: "17.0"
    MARKETING_VERSION: "1.0.0"
    CURRENT_PROJECT_VERSION: "1"

targets:
  {{PROJECT_NAME}}:
    type: application
    platform: iOS
    sources:
      - path: {{PROJECT_NAME}}
    resources:
      - path: {{PROJECT_NAME}}/Resources
    info:
      path: {{PROJECT_NAME}}/Info.plist
      properties:
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: false
          UISceneConfigurations: {}
        UILaunchScreen: {}
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: {{BUNDLE_PREFIX}}.{{project_name_lowercased}}
        INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone: "UIInterfaceOrientationPortrait"
        INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad: "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
    scheme:
      testTargets:
        - {{PROJECT_NAME}}Tests

  {{PROJECT_NAME}}Tests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: {{PROJECT_NAME}}Tests
    dependencies:
      - target: {{PROJECT_NAME}}
    settings:
      base:
        GENERATE_INFOPLIST_FILE: true
        BUNDLE_LOADER: "$(TEST_HOST)"
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/{{PROJECT_NAME}}.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/{{PROJECT_NAME}}"
```

**Adding SPM dependencies** — add a `packages` section and reference in target `dependencies`:

```yaml
packages:
  Nuke:
    url: https://github.com/kean/Nuke
    from: "12.0.0"

targets:
  {{PROJECT_NAME}}:
    # ... existing config ...
    dependencies:
      - package: Nuke
```

**Adding a widget extension**:

```yaml
targets:
  # ... existing targets ...

  {{PROJECT_NAME}}Widget:
    type: app-extension
    platform: iOS
    sources:
      - path: {{PROJECT_NAME}}Widget
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: {{BUNDLE_PREFIX}}.{{project_name_lowercased}}.widget
        GENERATE_INFOPLIST_FILE: true
        INFOPLIST_KEY_CFBundleDisplayName: "{{PROJECT_NAME}} Widget"
        INFOPLIST_KEY_NSExtension_NSExtensionPointIdentifier: com.apple.widgetkit-extension
    dependencies:
      - target: {{PROJECT_NAME}}
        embed: false
```

### Step 5: Create linting and formatting config

**`Mintfile`**:
```
realm/SwiftLint@0.57.0
nicklockwood/SwiftFormat@0.55.0
```

**`.swiftlint.yml`**:
```yaml
disabled_rules:
  - trailing_whitespace
  - line_length
opt_in_rules:
  - empty_count
  - closure_spacing
excluded:
  - .build
  - DerivedData
```

**`.swiftformat`**:
```
--swiftversion 6.0
--indent 4
--wrapcollections before-first
--maxwidth 120
```

### Step 6: Create `.gitignore` and copy scripts

Copy the XcodeGen-aware gitignore from the plugin template:

```bash
cp ${CLAUDE_PLUGIN_ROOT}/templates/gitignore/ios.gitignore .gitignore
```

Copy the simulator helper script:

```bash
cp ${CLAUDE_PLUGIN_ROOT}/templates/scripts/ios/sim.sh scripts/sim.sh
chmod +x scripts/sim.sh
# Replace placeholders in sim.sh:
# {{PROJECT_NAME}}, {{BUNDLE_PREFIX}}, {{PROJECT_NAME_LOWERCASE}}
```

Add `tmp/` to gitignore (for screenshots):

```bash
echo "" >> .gitignore
echo "# Preview screenshots" >> .gitignore
echo "tmp/" >> .gitignore
```

### Step 7: Generate the Xcode project and verify

```bash
# Install linting tools
mint bootstrap

# Generate the .xcodeproj
xcodegen generate

# Build to verify everything compiles
xcodebuild build \
  -scheme {{PROJECT_NAME}} \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -quiet

# Run tests to verify test target works
xcodebuild test \
  -scheme {{PROJECT_NAME}} \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -quiet
```

If `iPhone 16` simulator is not available, find one:
```bash
xcrun simctl list devices available | grep "iPhone" | head -5
```

### Step 8: Initialize git and commit

```bash
git init
git add .
git commit -m "Initial project setup"
```

This creates a clean initial commit with just the project files. Claude Code configuration is added in the next phase (see `setup-steps.md`).

---

---

## Reference Material

The sections below are not setup steps — they are decision guides and reference tables to consult when the project requirements call for specific choices.

## Decision Guide: Persistence

| Need | Choice | Setup |
|------|--------|-------|
| No local data / simple UserDefaults | None | No extra setup |
| Standard models, iCloud sync, simple queries | **SwiftData** | `@Model` classes + `.modelContainer(for:)` on App scene |
| Performance-critical, complex queries, precise migration control | **GRDB** | Add as SPM dependency |

SwiftData example:
```swift
@main
struct {{PROJECT_NAME}}App: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Recipe.self, Category.self])
    }
}
```

## Decision Guide: Additional Targets

| Feature | Add Target? |
|---------|-------------|
| Widget | Yes — `app-extension` with WidgetKit |
| Apple Watch companion | Yes — `application` with watchOS platform |
| Share extension | Yes — `app-extension` |
| iMessage app | Yes — `app-extension` |
| No extras | Single target is fine |

After adding targets to `project.yml`, regenerate with `xcodegen generate`.

## Common Libraries

Add only what the project needs. Prefer Apple frameworks when possible.

| Need | Library | `project.yml` key |
|------|---------|-------------------|
| Image loading/caching | Nuke | `from: "12.0.0"` |
| Keychain storage | KeychainAccess | `from: "4.2.2"` |
| SQLite persistence | GRDB | `from: "7.0.0"` |
| Snapshot testing | swift-snapshot-testing | `from: "1.17.0"` |

**Prefer Apple frameworks:**
- Charts → Swift Charts (iOS 16+)
- JSON → Codable (built-in)
- Networking → URLSession + async/await
- Persistence → SwiftData
- Auth → AuthenticationServices

## Rebuilding After Changes to `project.yml`

Any time `project.yml` is modified:

```bash
xcodegen generate
```

The `.xcodeproj` is not checked into git — it's always regenerated from `project.yml`.
