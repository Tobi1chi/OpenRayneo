import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val localProperties = Properties().apply {
    val file = rootProject.file("local.properties")
    if (file.isFile) file.inputStream().use(::load)
}

fun signingProperty(name: String): String? =
    System.getenv(name)?.takeIf { it.isNotBlank() }
        ?: localProperties.getProperty(name)?.takeIf { it.isNotBlank() }

android {
    namespace = "com.openrayneo.android"
    compileSdk = 36
    buildToolsVersion = "36.0.0"

    defaultConfig {
        applicationId = "com.openrayneo.android"
        minSdk = 33
        targetSdk = 36
        versionCode = 19
        versionName = "1.0.0"
    }

    val keystoreFile = signingProperty("OPENRAYNEO_KEYSTORE_FILE")?.let(::file)?.takeIf { it.isFile }
    val keystorePassword = signingProperty("OPENRAYNEO_KEYSTORE_PASSWORD")
    val keyAliasValue = signingProperty("OPENRAYNEO_KEY_ALIAS")
    val keyPasswordValue = signingProperty("OPENRAYNEO_KEY_PASSWORD")
    val hasExternalSigning =
        keystoreFile != null &&
            keystorePassword != null &&
            keyAliasValue != null &&
            keyPasswordValue != null

    signingConfigs {
        if (hasExternalSigning) {
            create("release") {
                storeFile = keystoreFile
                storePassword = keystorePassword
                keyAlias = keyAliasValue
                keyPassword = keyPasswordValue
            }
        }
    }

    buildTypes {
        getByName("release") {
            // Retains the existing debug certificate for in-place upgrades unless external signing is configured.
            signingConfig =
                if (hasExternalSigning) signingConfigs.getByName("release")
                else signingConfigs.getByName("debug")
            isDebuggable = false
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
    sourceSets {
        getByName("test") {
            resources.srcDir("../../Tests/Fixtures")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true; buildConfig = true }
}

dependencies {
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation(platform("androidx.compose:compose-bom:2025.04.01"))
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
