plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.legado.flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    sourceSets {
        getByName("main") {
            // Rust FFI .so 动态库（由 rust/scripts/build-android.ps1 生成）
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }

    defaultConfig {
        applicationId = "io.legado.flutter_legado"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
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

dependencies {
    // AndroidX Media（MediaSessionCompat + 音频焦点管理）
    implementation("androidx.media:media:1.7.0")
}

// 自动检测并复制 Rust FFI .so 文件（当 jniLibs 为空时从 rust/target 复制）
val rustTargetDir = file("${rootDir}/../../rust/target")
val jniLibsDir = file("src/main/jniLibs")
val abiMapping = mapOf(
    "aarch64-linux-android" to "arm64-v8a",
    "armv7-linux-androideabi" to "armeabi-v7a",
    "x86_64-linux-android" to "x86_64"
)

tasks.register("copyRustLibs") {
    description = "Copy Rust FFI .so files from rust/target to jniLibs"
    doLast {
        abiMapping.forEach { (triple, abi) ->
            val soFile = file("$rustTargetDir/$triple/release/liblegado_ffi.so")
            if (soFile.exists()) {
                val destDir = file("$jniLibsDir/$abi")
                destDir.mkdirs()
                soFile.copyTo(file("$destDir/liblegado_ffi.so"), overwrite = true)
                println("Copied: $abi/liblegado_ffi.so")
            }
        }
    }
}

// 如果 jniLibs 缺少 .so，在 preBuild 前自动复制
if (!file("$jniLibsDir/x86_64/liblegado_ffi.so").exists()
    && !file("$jniLibsDir/arm64-v8a/liblegado_ffi.so").exists()) {
    tasks.matching { it.name == "preBuild" }.configureEach {
        dependsOn("copyRustLibs")
    }
}
