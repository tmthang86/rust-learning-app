import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Values passed with `flutter build ... --dart-define=KEY=VALUE`. Flutter
// hands them to Gradle base64-encoded in the "dart-defines" property.
val dartDefines: Map<String, String> =
    (project.findProperty("dart-defines") as String?)
        ?.split(",")
        ?.filter { it.isNotBlank() }
        ?.map { String(Base64.getDecoder().decode(it)) }
        ?.filter { it.contains("=") }
        ?.associate { it.substringBefore("=") to it.substringAfter("=") }
        ?: emptyMap()

// Google's public TEST app id, used unless a real one is passed.
val admobTestAppId = "ca-app-pub-3940256099942544~3347511713"

android {
    namespace = "com.rustlearn.rust_learn"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.rustlearn.rust_learn"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["admobAppId"] =
            dartDefines["ADMOB_APP_ID_ANDROID"] ?: admobTestAppId
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// A release build must not ship Google's test app id: fail early (AGP's
// preReleaseBuild runs before compiling) unless the build says on purpose
// that it is a test build, with --dart-define=ALLOW_TEST_ADS_IN_RELEASE=true.
val releaseAppId = dartDefines["ADMOB_APP_ID_ANDROID"] ?: admobTestAppId
val allowTestAdsInRelease = dartDefines["ALLOW_TEST_ADS_IN_RELEASE"] == "true"
tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    doFirst {
        if (releaseAppId == admobTestAppId && !allowTestAdsInRelease) {
            throw GradleException(
                "Release build with the AdMob TEST app id. Pass the real ids, " +
                    "e.g. flutter build appbundle --dart-define-from-file=" +
                    "admob.json (see docs/ads-and-purchases.md), or add " +
                    "--dart-define=ALLOW_TEST_ADS_IN_RELEASE=true for a test build.",
            )
        }
    }
}
