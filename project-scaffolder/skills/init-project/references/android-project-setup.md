# Android Project Setup

Step-by-step instructions for creating a new Android project from scratch. All steps are CLI-executable — no Android Studio GUI interaction required.

This reference is used by the init-project skill when an Android project needs to be created. Only run this when no existing project is detected (no `build.gradle.kts`, `settings.gradle.kts`, or Kotlin source files).

Architecture and development patterns are covered separately in `ANDROID_APP_ARCHITECTURE_GUIDE.md`, not here.

---

## The Stack

| Layer | Choice |
|-------|--------|
| UI | Jetpack Compose |
| Min SDK | 26 (Android 8.0) |
| Target SDK | 36 (Android 15) |
| Language | Kotlin |
| Build system | Gradle with Kotlin DSL |
| Dependencies | Gradle version catalogs |
| Networking | Retrofit + OkHttp + Kotlinx Serialization |
| Persistence | Room (default) or DataStore (preferences) |
| DI | Hilt (Dagger) |
| Async | Coroutines + Flow |
| Navigation | Compose Navigation |
| Testing | JUnit5 + Compose UI Testing |
| Linting/Formatting | Detekt + ktlint (via detekt-formatting) |
| Logging | Timber |

**Why these choices:**

- **Jetpack Compose** is the modern declarative UI framework (like SwiftUI), avoiding the XML + View inflation pain of the older View system
- **Kotlin DSL** for Gradle provides type-safe build configuration (like Swift for XcodeGen)
- **Hilt** is Google's recommended DI solution built on Dagger with excellent Compose integration
- **Compose Previews** enable rapid iteration without running the full app (like SwiftUI previews)
- **Version catalogs** centralize dependency versions in `libs.versions.toml` for consistency

---

## Prerequisites

Check and install if missing:

```bash
# Java 17 (LTS) — required for Gradle and Android builds
java --version | grep -q "17\." || echo "Install Java 17 from https://adoptium.net"

# Android command-line tools — includes sdkmanager, avdmanager, adb
# Download from: https://developer.android.com/studio#command-line-tools-only
# Extract to ~/android-sdk/cmdline-tools/latest/

# Set environment variables (add to ~/.zshrc or ~/.bashrc)
export ANDROID_HOME="$HOME/android-sdk"
export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin"
export PATH="$PATH:$ANDROID_HOME/platform-tools"
export PATH="$PATH:$ANDROID_HOME/emulator"

# Install SDK components
sdkmanager --install "platform-tools" "platforms;android-36" "build-tools;35.0.0" \
  "emulator" "system-images;android-36;google_apis;arm64-v8a"

# Gradle wrapper will be created during project setup
# No separate installation needed
```

**Verification:**

```bash
# Check Java version
java -version  # Should show Java 17

# Check Android tools
sdkmanager --list | head -20
adb version
```

---

## Setup Procedure

Replace these placeholders throughout:
- `{{PROJECT_NAME}}` — the actual app name in PascalCase (e.g., `MyApp`)
- `{{PACKAGE_NAME}}` — the package name in reverse domain notation (e.g., `com.yourcompany.myapp`)
- `{{PROJECT_NAME_LOWERCASE}}` — the project name lowercased for schemes (e.g., `myapp`)

### Step 1: Create the directory structure

```bash
# Create root project directory
mkdir {{PROJECT_NAME}}
cd {{PROJECT_NAME}}

# Create source directories (standard Android structure)
mkdir -p app/src/main/kotlin/{{PACKAGE_PATH}}
mkdir -p app/src/main/kotlin/{{PACKAGE_PATH}}/ui/screens
mkdir -p app/src/main/kotlin/{{PACKAGE_PATH}}/ui/components
mkdir -p app/src/main/kotlin/{{PACKAGE_PATH}}/ui/theme
mkdir -p app/src/main/kotlin/{{PACKAGE_PATH}}/ui/navigation
mkdir -p app/src/main/kotlin/{{PACKAGE_PATH}}/data/repository
mkdir -p app/src/main/kotlin/{{PACKAGE_PATH}}/data/remote/api
mkdir -p app/src/main/kotlin/{{PACKAGE_PATH}}/data/remote/dto
mkdir -p app/src/main/kotlin/{{PACKAGE_PATH}}/domain/model
mkdir -p app/src/main/kotlin/{{PACKAGE_PATH}}/domain/repository
mkdir -p app/src/main/kotlin/{{PACKAGE_PATH}}/di
mkdir -p app/src/main/res/values
mkdir -p app/src/main/res/drawable

# Test directories
mkdir -p app/src/test/kotlin/{{PACKAGE_PATH}}
mkdir -p app/src/androidTest/kotlin/{{PACKAGE_PATH}}

# Scripts directory (for automation)
mkdir -p scripts

# Temp directory for screenshots (gitignored)
mkdir -p tmp

# Note: {{PACKAGE_PATH}} is {{PACKAGE_NAME}} with dots replaced by slashes
# e.g., com.yourcompany.myapp → com/yourcompany/myapp
```

### Step 2: Create Gradle build files

**Root `settings.gradle.kts`:**
```kotlin
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "{{PROJECT_NAME}}"
include(":app")
```

**Root `build.gradle.kts`:**
```kotlin
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.hilt) apply false
    alias(libs.plugins.ksp) apply false
    alias(libs.plugins.detekt) apply false
}
```

**`gradle/libs.versions.toml`** (version catalog):
```toml
[versions]
agp = "8.8.0"
kotlin = "2.1.0"
compose = "2026.01.00"
composeMaterial3 = "1.4.0"
hilt = "2.54"
retrofit = "2.11.0"
okhttp = "5.0.0-alpha.14"
room = "2.7.0"
kotlinx-serialization = "1.8.0"
navigation = "2.9.7"
lifecycle = "2.9.2"
timber = "5.1.0"
detekt = "1.23.8"
junit = "5.11.4"
ksp = "2.1.0-1.0.29"

[libraries]
# Compose
compose-bom = { group = "androidx.compose", name = "compose-bom", version.ref = "compose" }
compose-ui = { group = "androidx.compose.ui", name = "ui" }
compose-ui-tooling = { group = "androidx.compose.ui", name = "ui-tooling" }
compose-ui-tooling-preview = { group = "androidx.compose.ui", name = "ui-tooling-preview" }
compose-material3 = { group = "androidx.compose.material3", name = "material3", version.ref = "composeMaterial3" }
compose-navigation = { group = "androidx.navigation", name = "navigation-compose", version.ref = "navigation" }
compose-hilt-navigation = { group = "androidx.hilt", name = "hilt-navigation-compose", version = "1.2.0" }

# AndroidX
androidx-core = { group = "androidx.core", name = "core-ktx", version = "1.15.0" }
androidx-lifecycle-runtime = { group = "androidx.lifecycle", name = "lifecycle-runtime-ktx", version.ref = "lifecycle" }
androidx-lifecycle-viewmodel-compose = { group = "androidx.lifecycle", name = "lifecycle-viewmodel-compose", version.ref = "lifecycle" }
androidx-activity-compose = { group = "androidx.activity", name = "activity-compose", version = "1.10.0" }

# Hilt
hilt-android = { group = "com.google.dagger", name = "hilt-android", version.ref = "hilt" }
hilt-compiler = { group = "com.google.dagger", name = "hilt-compiler", version.ref = "hilt" }

# Networking
retrofit = { group = "com.squareup.retrofit2", name = "retrofit", version.ref = "retrofit" }
retrofit-kotlinx-serialization = { group = "com.squareup.retrofit2", name = "converter-kotlinx-serialization", version.ref = "retrofit" }
okhttp = { group = "com.squareup.okhttp3", name = "okhttp", version.ref = "okhttp" }
okhttp-logging = { group = "com.squareup.okhttp3", name = "logging-interceptor", version.ref = "okhttp" }
kotlinx-serialization-json = { group = "org.jetbrains.kotlinx", name = "kotlinx-serialization-json", version.ref = "kotlinx-serialization" }

# Room
room-runtime = { group = "androidx.room", name = "room-runtime", version.ref = "room" }
room-compiler = { group = "androidx.room", name = "room-compiler", version.ref = "room" }
room-ktx = { group = "androidx.room", name = "room-ktx", version.ref = "room" }

# Logging
timber = { group = "com.jakewharton.timber", name = "timber", version.ref = "timber" }

# Testing
junit-jupiter = { group = "org.junit.jupiter", name = "junit-jupiter", version.ref = "junit" }
compose-ui-test = { group = "androidx.compose.ui", name = "ui-test-junit4" }
compose-ui-test-manifest = { group = "androidx.compose.ui", name = "ui-test-manifest" }

[plugins]
android-application = { id = "com.android.application", version.ref = "agp" }
kotlin-android = { id = "org.jetbrains.kotlin.android", version.ref = "kotlin" }
kotlin-compose = { id = "org.jetbrains.kotlin.plugin.compose", version.ref = "kotlin" }
kotlin-serialization = { id = "org.jetbrains.kotlin.plugin.serialization", version.ref = "kotlin" }
hilt = { id = "com.google.dagger.hilt.android", version.ref = "hilt" }
ksp = { id = "com.google.devtools.ksp", version.ref = "ksp" }
detekt = { id = "io.gitlab.arturbosch.detekt", version.ref = "detekt" }
```

**`app/build.gradle.kts`:**
```kotlin
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.hilt)
    alias(libs.plugins.ksp)
    alias(libs.plugins.detekt)
}

android {
    namespace = "{{PACKAGE_NAME}}"
    compileSdk = 36

    defaultConfig {
        applicationId = "{{PACKAGE_NAME}}"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables {
            useSupportLibrary = true
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    // Compose BOM (Bill of Materials) manages Compose versions
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.compose.navigation)
    implementation(libs.compose.hilt.navigation)
    debugImplementation(libs.compose.ui.tooling)
    debugImplementation(libs.compose.ui.test.manifest)

    // AndroidX
    implementation(libs.androidx.core)
    implementation(libs.androidx.lifecycle.runtime)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)

    // Hilt
    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)

    // Networking
    implementation(libs.retrofit)
    implementation(libs.retrofit.kotlinx.serialization)
    implementation(libs.okhttp)
    implementation(libs.okhttp.logging)
    implementation(libs.kotlinx.serialization.json)

    // Room (optional - uncomment if needed)
    // implementation(libs.room.runtime)
    // implementation(libs.room.ktx)
    // ksp(libs.room.compiler)

    // Logging
    implementation(libs.timber)

    // Testing
    testImplementation(libs.junit.jupiter)
    androidTestImplementation(libs.compose.ui.test)
}

detekt {
    config.setFrom("$rootDir/config/detekt/detekt.yml")
    buildUponDefaultConfig = true
}
```

**`gradle.properties`:**
```properties
# Gradle settings
org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
org.gradle.parallel=true
org.gradle.caching=true

# Kotlin settings
kotlin.code.style=official

# Android settings
android.useAndroidX=true
android.nonTransitiveRClass=true
```

**`gradle/wrapper/gradle-wrapper.properties`:**
```properties
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-8.11.1-bin.zip
networkTimeout=10000
validateDistributionUrl=true
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
```

### Step 3: Create Android manifest and source files

**`app/src/main/AndroidManifest.xml`:**
```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-permission android:name="android.permission.INTERNET" />

    <application
        android:name=".{{PROJECT_NAME}}Application"
        android:allowBackup="true"
        android:icon="@mipmap/ic_launcher"
        android:label="@string/app_name"
        android:roundIcon="@mipmap/ic_launcher_round"
        android:supportsRtl="true"
        android:theme="@style/Theme.App">

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:theme="@style/Theme.App">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>

            <!-- Deep link support for automation -->
            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="{{PROJECT_NAME_LOWERCASE}}" />
            </intent-filter>
        </activity>
    </application>
</manifest>
```

**Application class** — `app/src/main/kotlin/{{PACKAGE_PATH}}/{{PROJECT_NAME}}Application.kt`:
```kotlin
package {{PACKAGE_NAME}}

import android.app.Application
import dagger.hilt.android.HiltAndroidApp
import timber.log.Timber

@HiltAndroidApp
class {{PROJECT_NAME}}Application : Application() {
    override fun onCreate() {
        super.onCreate()

        // Initialize Timber for logging
        if (BuildConfig.DEBUG) {
            Timber.plant(Timber.DebugTree())
        }

        Timber.d("Application initialized")
    }
}
```

**MainActivity** — `app/src/main/kotlin/{{PACKAGE_PATH}}/MainActivity.kt`:
```kotlin
package {{PACKAGE_NAME}}

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import dagger.hilt.android.AndroidEntryPoint
import {{PACKAGE_NAME}}.ui.navigation.AppNavHost
import {{PACKAGE_NAME}}.ui.theme.AppTheme
import timber.log.Timber

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        setContent {
            AppTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    AppNavHost(
                        initialDeepLink = intent?.data?.toString()
                    )
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Handle deep links when app is already running
        intent.data?.let { uri ->
            Timber.d("Deep link received: $uri")
            // Navigation handled in AppNavHost
        }
    }
}
```

**Navigation routes** — `app/src/main/kotlin/{{PACKAGE_PATH}}/ui/navigation/Routes.kt`:
```kotlin
package {{PACKAGE_NAME}}.ui.navigation

import kotlinx.serialization.Serializable

sealed interface Route {
    @Serializable
    data object Home : Route

    @Serializable
    data object Settings : Route

    // Add more routes as needed
    // @Serializable
    // data class Detail(val id: String) : Route
}
```

**Navigation host** — `app/src/main/kotlin/{{PACKAGE_PATH}}/ui/navigation/AppNavHost.kt`:
```kotlin
package {{PACKAGE_NAME}}.ui.navigation

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import {{PACKAGE_NAME}}.ui.screens.home.HomeScreen
import {{PACKAGE_NAME}}.ui.screens.settings.SettingsScreen
import timber.log.Timber

@Composable
fun AppNavHost(
    modifier: Modifier = Modifier,
    navController: NavHostController = rememberNavController(),
    initialDeepLink: String? = null
) {
    // Handle deep links
    initialDeepLink?.let { deepLink ->
        Timber.d("Handling deep link: $deepLink")
        when {
            deepLink.contains("settings") -> {
                // Navigate to settings after NavHost is composed
                navController.navigate(Route.Settings)
            }
            // Add more deep link handlers as needed
        }
    }

    NavHost(
        navController = navController,
        startDestination = Route.Home,
        modifier = modifier
    ) {
        composable<Route.Home> {
            HomeScreen(
                onNavigateToSettings = {
                    navController.navigate(Route.Settings)
                }
            )
        }

        composable<Route.Settings> {
            SettingsScreen(
                onBack = {
                    navController.popBackStack()
                }
            )
        }
    }
}
```

**Home screen** — `app/src/main/kotlin/{{PACKAGE_PATH}}/ui/screens/home/HomeScreen.kt`:
```kotlin
package {{PACKAGE_NAME}}.ui.screens.home

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import {{PACKAGE_NAME}}.ui.theme.AppTheme

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    onNavigateToSettings: () -> Unit = {}
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("{{PROJECT_NAME}}") },
                actions = {
                    IconButton(
                        onClick = onNavigateToSettings,
                        modifier = Modifier.semantics {
                            contentDescription = "Settings"
                        }
                    ) {
                        Icon(
                            imageVector = Icons.Default.Settings,
                            contentDescription = "Settings"
                        )
                    }
                }
            )
        }
    ) { paddingValues ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = "Hello, World!",
                style = MaterialTheme.typography.headlineMedium
            )
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun HomeScreenPreview() {
    AppTheme {
        HomeScreen()
    }
}
```

**Settings screen** — `app/src/main/kotlin/{{PACKAGE_PATH}}/ui/screens/settings/SettingsScreen.kt`:
```kotlin
package {{PACKAGE_NAME}}.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.tooling.preview.Preview
import {{PACKAGE_NAME}}.ui.theme.AppTheme

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onBack: () -> Unit = {}
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(
                        onClick = onBack,
                        modifier = Modifier.semantics {
                            contentDescription = "Back"
                        }
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back"
                        )
                    }
                }
            )
        }
    ) { paddingValues ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = "Settings",
                style = MaterialTheme.typography.headlineMedium
            )
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun SettingsScreenPreview() {
    AppTheme {
        SettingsScreen()
    }
}
```

**Theme** — `app/src/main/kotlin/{{PACKAGE_PATH}}/ui/theme/Theme.kt`:
```kotlin
package {{PACKAGE_NAME}}.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext

private val LightColorScheme = lightColorScheme(
    primary = Purple40,
    secondary = PurpleGrey40,
    tertiary = Pink40
)

private val DarkColorScheme = darkColorScheme(
    primary = Purple80,
    secondary = PurpleGrey80,
    tertiary = Pink80
)

@Composable
fun AppTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = true,
    content: @Composable () -> Unit
) {
    val colorScheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }
        darkTheme -> DarkColorScheme
        else -> LightColorScheme
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = Typography,
        content = content
    )
}
```

**Colors** — `app/src/main/kotlin/{{PACKAGE_PATH}}/ui/theme/Color.kt`:
```kotlin
package {{PACKAGE_NAME}}.ui.theme

import androidx.compose.ui.graphics.Color

val Purple80 = Color(0xFFD0BCFF)
val PurpleGrey80 = Color(0xFFCCC2DC)
val Pink80 = Color(0xFFEFB8C8)

val Purple40 = Color(0xFF6650a4)
val PurpleGrey40 = Color(0xFF625b71)
val Pink40 = Color(0xFF7D5260)
```

**Typography** — `app/src/main/kotlin/{{PACKAGE_PATH}}/ui/theme/Type.kt`:
```kotlin
package {{PACKAGE_NAME}}.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

val Typography = Typography(
    bodyLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 16.sp,
        lineHeight = 24.sp,
        letterSpacing = 0.5.sp
    )
)
```

**Resources** — `app/src/main/res/values/strings.xml`:
```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">{{PROJECT_NAME}}</string>
</resources>
```

**Resources** — `app/src/main/res/values/themes.xml`:
```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="Theme.App" parent="android:Theme.Material.Light.NoActionBar" />
</resources>
```

**Test file** — `app/src/test/kotlin/{{PACKAGE_PATH}}/ExampleTest.kt`:
```kotlin
package {{PACKAGE_NAME}}

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class ExampleTest {
    @Test
    fun `addition works correctly`() {
        assertEquals(4, 2 + 2)
    }
}
```

### Step 4: Create linting configuration

**`config/detekt/detekt.yml`:**
```yaml
build:
  maxIssues: 0

formatting:
  active: true
  android: true
  autoCorrect: true

complexity:
  LongMethod:
    active: true
    threshold: 60
  ComplexMethod:
    active: true
    threshold: 15

style:
  MagicNumber:
    active: false
  MaxLineLength:
    active: true
    maxLineLength: 120
```

Add to root `build.gradle.kts`:
```kotlin
// At the end of the file
tasks.register("detektAll") {
    dependsOn(gradle.includedBuild("app").task(":detekt"))
}
```

### Step 5: Create `.gitignore`

**`.gitignore`:**
```gitignore
# Gradle files
.gradle/
build/
gradle-app.setting
!gradle-wrapper.jar

# Local configuration
local.properties
*.iml
.idea/
.DS_Store

# Built application files
*.apk
*.ap_
*.aab

# Files for the ART/Dalvik VM
*.dex

# Java class files
*.class

# Generated files
bin/
gen/
out/

# Keystore files
*.jks
*.keystore

# External native build
.cxx/
.externalNativeBuild/

# Version control
.svn/

# OS-specific files
.DS_Store
.DS_Store?
._*
.Spotlight-V100
.Trashes
ehthumbs.db
Thumbs.db

# Preview screenshots
tmp/

# Android Studio
captures/
.navigation/
```

### Step 6: Create Gradle wrapper

```bash
# Initialize Gradle wrapper
gradle wrapper --gradle-version 8.11.1

# Make gradlew executable
chmod +x gradlew
```

### Step 7: Create automation script

**`scripts/emu.sh`** (emulator automation helper):
```bash
#!/bin/bash
# Emulator automation script for {{PROJECT_NAME}}

PACKAGE_NAME="{{PACKAGE_NAME}}"
SCHEME="{{PROJECT_NAME_LOWERCASE}}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCREENSHOT_DIR="$PROJECT_DIR/tmp"

# Ensure screenshot directory exists
mkdir -p "$SCREENSHOT_DIR"

# Helper functions
get_device() {
    adb devices | grep -E "device$" | awk '{print $1}' | head -1
}

wait_for_device() {
    echo "Waiting for device..."
    adb wait-for-device
    sleep 2
}

# Commands
cmd_build() {
    echo "Building APK..."
    cd "$PROJECT_DIR"
    ./gradlew assembleDebug
}

cmd_install() {
    echo "Installing APK..."
    ./gradlew installDebug
}

cmd_launch() {
    echo "Launching app..."
    adb shell am start -n "$PACKAGE_NAME/.MainActivity"
}

cmd_screenshot() {
    local filename="${1:-preview.png}"
    echo "Taking screenshot..."
    adb exec-out screencap -p > "$SCREENSHOT_DIR/$filename"
    echo "Screenshot saved to $SCREENSHOT_DIR/$filename"
}

cmd_deeplink() {
    local path="$1"
    echo "Opening deep link: $SCHEME://$path"
    adb shell am start -W -a android.intent.action.VIEW -d "$SCHEME://$path" "$PACKAGE_NAME"
}

cmd_tap() {
    local label="$1"
    echo "Tapping element with content description: $label"
    # Use UI Automator to find and tap element
    adb shell uiautomator runtest << EOF
ui_object = device.findObject(new UiSelector().descriptionContains("$label"))
if ui_object.exists():
    ui_object.click()
EOF
}

cmd_back() {
    echo "Pressing back button..."
    adb shell input keyevent KEYCODE_BACK
}

cmd_home() {
    echo "Pressing home button..."
    adb shell input keyevent KEYEVENT_HOME
}

cmd_text() {
    local text="$1"
    echo "Typing text: $text"
    adb shell input text "$text"
}

cmd_logcat() {
    echo "Showing logcat (Timber logs)..."
    adb logcat -s "$PACKAGE_NAME:D" "*:E"
}

# Main command router
case "$1" in
    build)
        cmd_build
        ;;
    install)
        cmd_install
        ;;
    launch)
        cmd_launch
        ;;
    screenshot)
        wait_for_device
        cmd_screenshot "$2"
        ;;
    deeplink)
        wait_for_device
        cmd_deeplink "$2"
        ;;
    tap)
        wait_for_device
        cmd_tap "$2"
        ;;
    back)
        wait_for_device
        cmd_back
        ;;
    home)
        wait_for_device
        cmd_home
        ;;
    text)
        wait_for_device
        cmd_text "$2"
        ;;
    logcat)
        wait_for_device
        cmd_logcat
        ;;
    all)
        # Build, install, launch workflow
        cmd_build && cmd_install && cmd_launch
        ;;
    *)
        echo "Usage: $0 {build|install|launch|screenshot|deeplink|tap|back|home|text|logcat|all}"
        echo ""
        echo "Commands:"
        echo "  build              - Build the debug APK"
        echo "  install            - Install the APK to connected device/emulator"
        echo "  launch             - Launch the app"
        echo "  screenshot [name]  - Take screenshot (default: preview.png)"
        echo "  deeplink <path>    - Open deep link (e.g., 'settings')"
        echo "  tap <label>        - Tap element by content description"
        echo "  back               - Press back button"
        echo "  home               - Press home button"
        echo "  text <text>        - Type text"
        echo "  logcat             - Show app logs"
        echo "  all                - Build, install, and launch"
        exit 1
        ;;
esac
```

```bash
chmod +x scripts/emu.sh
```

### Step 8: Verify the build

```bash
# Build the project
./gradlew build

# Create an AVD if one doesn't exist
avdmanager create avd -n test_avd -k "system-images;android-36;google_apis;arm64-v8a" -d pixel_6

# Start emulator (in background)
emulator -avd test_avd -no-snapshot-load &

# Wait for device
adb wait-for-device

# Install and launch
./scripts/emu.sh all

# Take a screenshot
./scripts/emu.sh screenshot initial.png

# Test deep linking
./scripts/emu.sh deeplink settings
```

### Step 9: Initialize git and commit

```bash
git init
git add .
git commit -m "Initial Android project setup

- Jetpack Compose UI with Material 3
- Hilt dependency injection
- Navigation with deep link support
- Detekt linting configuration
- Emulator automation scripts"
```

---

## Reference Material

The sections below are not setup steps — they are decision guides and reference tables to consult when project requirements call for specific choices.

### Decision Guide: Persistence

| Need | Choice | Setup |
|------|--------|-------|
| Simple key-value preferences | **DataStore** | Add `androidx.datastore:datastore-preferences` |
| Structured local data, queries | **Room** | Add Room dependencies (uncomment in build.gradle.kts), create entities, DAOs, database |
| File storage | **File API** | Use `context.filesDir` or `context.cacheDir` |
| No local data | None | No extra setup |

**Room example:**
```kotlin
// Entity
@Entity(tableName = "users")
data class User(
    @PrimaryKey val id: String,
    val name: String
)

// DAO
@Dao
interface UserDao {
    @Query("SELECT * FROM users")
    fun getAll(): Flow<List<User>>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(user: User)
}

// Database
@Database(entities = [User::class], version = 1)
abstract class AppDatabase : RoomDatabase() {
    abstract fun userDao(): UserDao
}

// Hilt module
@Module
@InstallIn(SingletonComponent::class)
object DatabaseModule {
    @Provides
    @Singleton
    fun provideDatabase(@ApplicationContext context: Context): AppDatabase {
        return Room.databaseBuilder(
            context,
            AppDatabase::class.java,
            "app-database"
        ).build()
    }

    @Provides
    fun provideUserDao(database: AppDatabase): UserDao {
        return database.userDao()
    }
}
```

### Decision Guide: Image Loading

| Need | Choice | Setup |
|------|--------|-------|
| Image loading/caching | **Coil** | Add `io.coil-kt:coil-compose:3.0.4` |
| No image loading | None | Use built-in Image composable |

**Coil example:**
```kotlin
AsyncImage(
    model = "https://example.com/image.jpg",
    contentDescription = "Image",
    modifier = Modifier.size(200.dp)
)
```

### Decision Guide: Additional Features

| Feature | Library | Version Catalog Entry |
|---------|---------|----------------------|
| Maps | Google Maps Compose | `maps-compose = "6.2.1"` |
| Camera | CameraX | `camerax-core = "1.4.1"` |
| Permissions | Accompanist Permissions | `accompanist-permissions = "0.36.0"` |
| Paging | AndroidX Paging 3 | `paging = "3.3.5"` |
| WorkManager | AndroidX Work | `work = "2.10.0"` |

### Common Gradle Tasks

```bash
# Build debug APK
./gradlew assembleDebug

# Build release APK
./gradlew assembleRelease

# Run unit tests
./gradlew test

# Run instrumented tests
./gradlew connectedAndroidTest

# Run linting
./gradlew detekt

# Clean build
./gradlew clean

# Install debug APK
./gradlew installDebug

# View all tasks
./gradlew tasks --all
```

### Compose Preview Tips

**Previews are your rapid feedback loop** (like SwiftUI previews):

```kotlin
@Preview(name = "Light Mode", showBackground = true)
@Preview(name = "Dark Mode", uiMode = Configuration.UI_MODE_NIGHT_YES, showBackground = true)
@Composable
private fun ComponentPreview() {
    AppTheme {
        MyComponent()
    }
}

// Preview with parameters
@Preview(showBackground = true)
@Composable
private fun ComponentWithDataPreview() {
    AppTheme {
        MyComponent(
            data = PreviewData.sampleData
        )
    }
}
```

**Interactive previews:** In Android Studio, click the play button in previews to run them in an interactive mode where you can click buttons and see state changes.

**Live Edit:** Android Studio supports Live Edit for Compose — changes to `@Composable` functions update in the preview instantly without rebuilding.

### Deep Link Testing

Test deep links via ADB:

```bash
# Open home
adb shell am start -W -a android.intent.action.VIEW \
  -d "{{PROJECT_NAME_LOWERCASE}}://home" {{PACKAGE_NAME}}

# Open settings
adb shell am start -W -a android.intent.action.VIEW \
  -d "{{PROJECT_NAME_LOWERCASE}}://settings" {{PACKAGE_NAME}}

# Open detail with parameter
adb shell am start -W -a android.intent.action.VIEW \
  -d "{{PROJECT_NAME_LOWERCASE}}://detail/123" {{PACKAGE_NAME}}
```

### Emulator Automation

The `scripts/emu.sh` script provides automation similar to iOS's `sim.sh`:

```bash
# Build, install, launch
./scripts/emu.sh all

# Navigate via deep link
./scripts/emu.sh deeplink settings

# Take screenshot
./scripts/emu.sh screenshot after_change.png

# Tap button by content description
./scripts/emu.sh tap "Settings"

# Go back
./scripts/emu.sh back
```

**For AI agents:** Use these scripts in combination with screenshot analysis to verify UI changes programmatically.

### Dependency Updates

Update dependencies in `gradle/libs.versions.toml`:

```toml
[versions]
compose = "2026.02.00"  # Update version
```

Then run:
```bash
./gradlew --refresh-dependencies
```

---

## Sources

Research for this guide consulted the following resources:

- [Jetpack Compose Setup - Android Developers](https://developer.android.com/develop/ui/compose/setup)
- [Build from Command Line - Android Developers](https://developer.android.com/build/building-cmdline)
- [Gradle Kotlin DSL Primer](https://docs.gradle.org/current/userguide/kotlin_dsl.html)
- [Android Debug Bridge (adb) - Android Developers](https://developer.android.com/tools/adb)
- [Compose Previews - Android Developers](https://developer.android.com/develop/ui/compose/tooling/previews)
- [Deep Linking - Android Developers](https://developer.android.com/training/app-links/deep-linking)
- [Hilt Dependency Injection - Android Developers](https://developer.android.com/training/dependency-injection/hilt-android)
- [Detekt Static Analysis](https://github.com/detekt/detekt)
- [Command-line tools - Android Developers](https://developer.android.com/tools)
- [Navigation with Compose - Android Developers](https://developer.android.com/develop/ui/compose/navigation)
