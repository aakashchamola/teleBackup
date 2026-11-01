import java.util.Properties

plugins {
    id("com.android.application")
    id("com.google.devtools.ksp")
    id("org.jetbrains.kotlin.plugin.serialization")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The release key stays outside the repo. app/android/key.properties (git-ignored) points to it (docs/phases/M7.md).
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKey = keyProps.getProperty("storeFile") != null
// For checking a release build on a computer without the family key. Never for APKs that are handed out.
val debugSignedRelease = System.getenv("TELEBACKUP_DEBUG_SIGNED_RELEASE") == "1"

android {
    namespace = "com.aakashchamola.telebackup"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.aakashchamola.telebackup"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 30
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    sourceSets {
        // the exported Room schemas, for the migration test
        getByName("androidTest").assets.srcDir("$projectDir/schemas")
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
        unitTests.isReturnDefaultValues = true
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = when {
                hasReleaseKey -> signingConfigs.getByName("release")
                debugSignedRelease -> signingConfigs.getByName("debug")
                else -> null
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

ksp {
    arg("room.schemaLocation", "$projectDir/schemas")
}

dependencies {
    implementation("androidx.room:room-runtime:2.8.5")
    implementation("androidx.room:room-ktx:2.8.5")
    ksp("androidx.room:room-compiler:2.8.5")
    implementation("androidx.work:work-runtime-ktx:2.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.12.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // TDLib 1.8.67 for the Telegram account (big files, strong check). A community build of the official sources:
    // SHA-256 of core-0.1.1.aar is 1ec6d6c6c83b655349d8a91182145cdd5400392246136ad79432253ad6004106 (docs/STATUS.md).
    // Before a family release this should be swapped for a build made from tdlib/td itself (same org.drinkless.tdlib API).
    implementation("io.github.tdlib-android:core:0.1.1")
    // Sorting photos of documents into their own topic: Google's text reader, model bundled in the app, works offline.
    implementation("com.google.mlkit:text-recognition:16.0.1")
    implementation("com.google.mlkit:image-labeling:17.0.9")
    implementation("androidx.exifinterface:exifinterface:1.4.1")

    testImplementation("junit:junit:4.13.2")
    testImplementation("com.google.truth:truth:1.4.5")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    testImplementation("androidx.work:work-testing:2.12.0")
    testImplementation("org.robolectric:robolectric:4.17")
    testImplementation("androidx.room:room-testing:2.8.5")

    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.room:room-testing:2.8.5")
    androidTestImplementation("com.google.truth:truth:1.4.5")
    androidTestImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
}

flutter {
    source = "../.."
}

// Flutter's asset copy task is not declared as an input of the unit-test packaging task; Gradle 9 refuses that.
afterEvaluate {
    tasks.matching { it.name.startsWith("package") && it.name.endsWith("UnitTestForUnitTest") }.configureEach {
        val variant = name.removePrefix("package").removeSuffix("UnitTestForUnitTest")
        tasks.findByName("copyFlutterAssets$variant")?.let { dependsOn(it) }
    }
}

// A release build without the family key must fail loudly, not hand out an unsigned or debug-signed APK.
gradle.taskGraph.whenReady {
    val building = allTasks.any { it.path.startsWith(":app:") && (it.name == "assembleRelease" || it.name == "bundleRelease") }
    if (building && !hasReleaseKey && !debugSignedRelease) {
        throw GradleException("Release signing key missing. Make key.properties as described in docs/phases/M7.md (or set TELEBACKUP_DEBUG_SIGNED_RELEASE=1 to check a build on this computer only).")
    }
}
