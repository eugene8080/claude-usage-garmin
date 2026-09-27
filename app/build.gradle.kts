import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Load release signing config from a gitignored keystore.properties, if present.
// Without it (e.g. a fresh clone), the release build simply stays unsigned and
// everything still compiles.
val keystorePropsFile = rootProject.file(".signing/keystore.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) {
        keystorePropsFile.inputStream().use { load(it) }
    }
}
val hasReleaseSigning = keystoreProps.isNotEmpty()

android {
    namespace = "com.usage.claudewidget"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.usage.claudewidget"
        minSdk = 26
        targetSdk = 36
        versionCode = 3
        // CI overwrites this with the release tag (see .github/workflows/build.yml). The
        // default is "dev" rather than a number so a locally-built APK is unmistakably not a
        // release when its version is shown in the app / widget / on the watch.
        versionName = "dev"

        // Point the Connect IQ SDK at the simulator instead of a real watch:
        //   ./gradlew assembleDebug -PciqTethered=true
        // then `adb forward tcp:7381 tcp:7381` and start the simulator's adb connection.
        // A build flag rather than a runtime setting, so a shipped build cannot be talked
        // into tethered mode and there is no dev-only switch in the UI.
        buildConfigField(
            "boolean",
            "CIQ_TETHERED",
            (project.findProperty("ciqTethered") == "true").toString(),
        )
    }

    buildFeatures {
        // Required for BuildConfig.CIQ_TETHERED; AGP 8 does not generate BuildConfig unless
        // it is asked to.
        buildConfig = true
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            // Use the private key for debug builds too when one is configured, so an APK
            // pulled from an Actions run installs over a release rather than colliding
            // with it. Without a key AGP falls back to a per-machine debug keystore, and
            // a CI runner is a new machine every run — which is how consecutive releases
            // ended up signed differently and refusing to install over each other.
            if (hasReleaseSigning) signingConfig = signingConfigs.getByName("release")
        }
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    buildFeatures { compose = true }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.appcompat:appcompat:1.7.0")

    // Compose (for the debug/setup screen)
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")

    // Glance App Widget
    implementation("androidx.glance:glance-appwidget:1.1.1")
    implementation("androidx.glance:glance-material3:1.1.1")

    // Background work
    implementation("androidx.work:work-runtime-ktx:2.10.0")

    // Networking
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // Encrypted storage
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // Garmin Connect IQ companion SDK - pushes the usage snapshot to the watch app.
    // The same artifact drives both a real watch (via Garmin Connect Mobile) and the
    // Connect IQ simulator over adb; see WatchBridge and garmin/watch-app/README.md.
    implementation("com.garmin.connectiq:ciq-companion-app-sdk:2.4.0")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}
