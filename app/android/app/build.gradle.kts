import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 簽章：本機讀 android/keystore/keystore.properties，CI 讀環境變數（GitHub Secrets）
val keystoreProps = Properties().apply {
    val f = rootProject.file("keystore/keystore.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
fun signingValue(prop: String, env: String): String? = System.getenv(env) ?: keystoreProps.getProperty(prop)

val releaseStoreFile = signingValue("storeFile", "SIGNING_STORE_FILE")?.let { rootProject.file(it) }
// CI 以 build 編號當 versionCode，新版才能覆蓋安裝舊版；本機建置是「開發版」
val buildNumber = System.getenv("BUILD_NUMBER")?.toIntOrNull()

android {
    namespace = "com.allinoneplayer"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 24
        targetSdk = 36
        versionCode = buildNumber ?: 1
        versionName = buildNumber?.let { "1.0.$it" } ?: "1.0.dev"
    }

    flavorDimensions += "device"
    productFlavors {
        create("phone") {
            dimension = "device"
            applicationId = "com.allinoneplayer.app"
            resValue("string", "app_name", "AllinOnePlayer")
            buildConfigField("boolean", "IS_TV", "false")
            buildConfigField("String", "APK_NAME", "\"AllinOnePlayer.apk\"")
        }
        create("tv") {
            dimension = "device"
            applicationId = "com.allinoneplayer.tv"
            resValue("string", "app_name", "AllinOnePlayer TV")
            buildConfigField("boolean", "IS_TV", "true")
            buildConfigField("String", "APK_NAME", "\"AllinOnePlayerTV.apk\"")
        }
    }

    signingConfigs {
        if (releaseStoreFile?.exists() == true) {
            create("release") {
                storeFile = releaseStoreFile
                storePassword = signingValue("storePassword", "SIGNING_STORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "SIGNING_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "SIGNING_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    buildFeatures {
        buildConfig = true
        resValues = true
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
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

dependencies {
    val media3 = "1.6.1"
    implementation("androidx.media3:media3-exoplayer:$media3")
    implementation("androidx.media3:media3-exoplayer-hls:$media3")
    implementation("androidx.media3:media3-datasource-okhttp:$media3")
    implementation("androidx.media3:media3-datasource-cronet:$media3")
    implementation("androidx.media3:media3-ui:$media3")
    // CDN 會看連線指紋：優先用 Play 服務提供的 Cronet（Chrome 同一套網路層），沒有才退回 OkHttp
    implementation("com.google.android.gms:play-services-cronet:18.1.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("androidx.activity:activity-ktx:1.10.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.9.1")
    implementation("androidx.core:core-ktx:1.16.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
