plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.shayneeo.localshare"
    compileSdk = 35
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
    applicationId = "com.shayneeo.localshare"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion  // Supports Android 5.0+, reduces APK size
        targetSdk = 35  // Android 15
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Note: abiFilters removed - using --split-per-abi flag instead
    }

    buildTypes {
        release {
            // Signing with the debug keys for now
            signingConfig = signingConfigs.getByName("debug")
            // Enable code shrinking, obfuscation, and optimization
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Required for SplitCompatApplication referenced by Flutter Play Store split support
    implementation("com.google.android.play:core:1.10.3")
}
