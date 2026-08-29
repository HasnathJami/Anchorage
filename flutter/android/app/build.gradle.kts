plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Pinned, not inherited — the mirror of the same block in the Android app.
// `flutter build apk` resolves its JDK from `flutter config --jdk-dir`, the IDE
// from its own Gradle JVM setting, and a bare `./gradlew` from JAVA_HOME. Those
// three drift independently; the toolchain makes all three compile at 17.
kotlin {
    jvmToolchain(17)
}

android {
    namespace = "com.anchorage.anchorage_harbor"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.anchorage.anchorage_harbor"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // camera + permission_handler both require 21+; 24 keeps the modern
        // WorkManager scheduling behaviour without a compat branch.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
