// SPDX-License-Identifier: GPL-3.0-or-later
// Configures the native Android app, development version and build inputs.
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

val releaseStorePath = providers.environmentVariable("ANICE_ANDROID_KEYSTORE").orNull
val releaseStorePassword = providers.environmentVariable("ANICE_ANDROID_STORE_PASSWORD").orNull
val releaseKeyAlias = providers.environmentVariable("ANICE_ANDROID_KEY_ALIAS").orNull
val releaseKeyPassword = providers.environmentVariable("ANICE_ANDROID_KEY_PASSWORD").orNull
val releaseSigningReady = listOf(releaseStorePath, releaseStorePassword, releaseKeyAlias, releaseKeyPassword).all { !it.isNullOrBlank() }
val previewBuild = providers.gradleProperty("anicePreview").orNull == "true"

android {
    signingConfigs {
        create("production") {
            if (releaseSigningReady) {
                storeFile = file(requireNotNull(releaseStorePath))
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }
    buildTypes {
        debug {
            if (previewBuild) {
                applicationIdSuffix = ".preview"
                manifestPlaceholders["aniceAppLabel"] = "aniCe Preview"
            }
        }
        release { if (releaseSigningReady) signingConfig = signingConfigs.getByName("production") }
    }
    namespace = "io.github.anisharyal09.anice"
    compileSdk = 36
    ndkVersion = "27.3.13750724"
    defaultConfig {
        applicationId = "io.github.anisharyal09.anice"
        manifestPlaceholders["aniceAppLabel"] = "@string/app_name"
        minSdk = 29
        targetSdk = 36
        versionCode = providers.gradleProperty("aniceVersionCode").orNull?.toInt() ?: 90021
        versionName = providers.gradleProperty("aniceVersionName").orNull ?: "0.9.0-beta.1"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { compose = true }
    sourceSets.getByName("main").jniLibs.srcDir("build/native")
    sourceSets.getByName("main").assets.srcDir("build/pairing-notices")
    sourceSets.getByName("test").resources.directories.add("../../../protocol/test-vectors")
    sourceSets.getByName("androidTest").assets.directories.add("../../../protocol/test-vectors")
}
kotlin {
    compilerOptions { jvmTarget = JvmTarget.JVM_17 }
}
val buildPairingNative by tasks.registering(Exec::class) {
    workingDir(rootProject.projectDir.parentFile.parentFile)
    commandLine("python3", "scripts/build-pairing-native.py", "android")
    inputs.dir("../../../core/rust/pairing/src")
    inputs.file("../../../core/rust/pairing/Cargo.lock")
    inputs.file("../../../core/rust/pairing/THIRD_PARTY_NOTICES.md")
    inputs.file("../../../scripts/build-pairing-native.py")
    // InputFiles tracks private overrides when present without requiring them on clean runners.
    inputs.files(rootProject.file("local.properties"))
    outputs.dir("build/native")
    outputs.dir("build/pairing-notices")
    doLast { copy { from("../../../core/rust/pairing/THIRD_PARTY_NOTICES.md"); into("build/pairing-notices") } }
}
tasks.named("preBuild") { dependsOn(buildPairingNative) }
dependencies {
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("androidx.camera:camera-camera2:1.5.3")
    implementation("androidx.camera:camera-lifecycle:1.5.3")
    implementation("androidx.camera:camera-view:1.5.3")
    implementation("com.google.zxing:core:3.5.3")
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.10.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel:2.10.0")
    implementation("androidx.activity:activity-compose:1.12.4")
    implementation(platform("androidx.compose:compose-bom:2026.02.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20260814")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
}

// Public releases must never fall back to an unsigned or debug-signed APK.
tasks.configureEach {
    if (name == "packageRelease") {
        doFirst {
            check(!previewBuild) { "Preview builds are Debug-only and cannot be packaged as a release." }
            check(releaseSigningReady) { "Set ANICE_ANDROID_KEYSTORE, ANICE_ANDROID_STORE_PASSWORD, ANICE_ANDROID_KEY_ALIAS and ANICE_ANDROID_KEY_PASSWORD for a release build." }
        }
    }
}
