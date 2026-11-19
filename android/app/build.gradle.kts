plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.openrayneo.android"
    compileSdk = 36
    buildToolsVersion = "36.0.0"

    defaultConfig {
        applicationId = "com.openrayneo.android"
        minSdk = 33
        targetSdk = 36
        versionCode = 38
        versionName = "1.2.0-beta.5"
        ndk { abiFilters += providers.gradleProperty("openrayneo.abis").orElse("arm64-v8a").get().split(',') }
    }
    buildTypes {
        getByName("release") {
            // Direct-distribution Beta retains the existing certificate for in-place upgrades.
            signingConfig = signingConfigs.getByName("debug")
            isDebuggable = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true; buildConfig = true }
    androidResources { noCompress += "onnx" }
    sourceSets.getByName("main").assets.srcDir("../../ThirdParty/SherpaOnnx")
    sourceSets.getByName("main").assets.srcDir(layout.buildDirectory.dir("generated/glasses-model"))
}

// The live 3D glasses load the shared model from assets/models; only the glb ships in the APK.
val glassesModel by tasks.registering(Sync::class) {
    from(rootProject.file("../assets/models/rayneo-io.glb"))
    into(layout.buildDirectory.dir("generated/glasses-model/models"))
}

val prepareVoiceModels by tasks.registering(Exec::class) {
    commandLine("sh", rootProject.file("../scripts/prepare-android-voice.sh"))
    outputs.files(file("libs/sherpa-onnx-2.0.1.aar"), file("src/main/assets/voice-models/campplus-zh-16k.onnx"),
        file("src/main/assets/voice-models/silero-vad.onnx"), file("src/main/assets/voice-models/segmentation.int8.onnx"))
}
tasks.named("preBuild") { dependsOn(prepareVoiceModels, glassesModel) }

dependencies {
    implementation(files("libs/sherpa-onnx-2.0.1.aar"))
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.google.android.filament:filament-android:1.75.1")
    implementation("com.google.android.filament:gltfio-android:1.75.1")
    implementation(platform("androidx.compose:compose-bom:2025.04.01"))
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
}
