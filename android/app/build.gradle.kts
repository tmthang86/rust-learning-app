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

// A release build must not ship Google's test app id, or the placeholder ad
// report address (App Store guideline 2.5.18 needs a real way to report
// ads; the same build feeds both stores). It fails early (AGP's
// preReleaseBuild runs before compiling) unless the build says on purpose
// that it is a test build, with --dart-define=ALLOW_TEST_ADS_IN_RELEASE=true.
// The message is computed here, so the task action captures only a String
// (works with the configuration cache).
val releaseAdsProblem: String? = run {
    if (dartDefines["ALLOW_TEST_ADS_IN_RELEASE"] == "true") return@run null
    val appId = dartDefines["ADMOB_APP_ID_ANDROID"] ?: admobTestAppId
    val reportEmail = dartDefines["AD_REPORT_EMAIL"].orEmpty()
    val reportUrl = dartDefines["AD_REPORT_URL"].orEmpty()
    val problems = buildList {
        if (appId == admobTestAppId) add("the AdMob TEST app id")
        if (reportUrl.isEmpty() &&
            (reportEmail.isEmpty() || reportEmail == "ads-report@example.com")
        ) {
            add("no real AD_REPORT_EMAIL or AD_REPORT_URL")
        }
    }
    if (problems.isEmpty()) {
        null
    } else {
        "Release build with " + problems.joinToString(" and ") + ". Pass " +
            "the real values, e.g. flutter build appbundle " +
            "--dart-define-from-file=admob.json (see docs/ads-and-purchases.md), " +
            "or add --dart-define=ALLOW_TEST_ADS_IN_RELEASE=true for a test build."
    }
}
tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    val problem = releaseAdsProblem
    doFirst {
        if (problem != null) throw GradleException(problem)
    }
}
