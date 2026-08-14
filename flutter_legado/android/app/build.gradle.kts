plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import org.gradle.api.GradleException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files

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

// ========== Rust FFI content hash 校验（根治「引擎初始化失败」）==========
// jniLibs 在 .gitignore，改 FRB/Rust 后若未重编 .so 会导致运行时 hash 失配。
// preBuild 前校验 Dart 侧 rustContentHash 与 jniLibs 中 .so/.meta 一致；
// 可通过 LEGADO_SKIP_RUST_BUILD=1 跳过（纯 Dart Mock 开发者）。
val jniLibsDir = file("src/main/jniLibs")
val dartFrbFile = file("../../lib/src/bridge/frb_generated.dart")
val rustFrbFile = file("../../../rust/legado-ffi/src/frb_generated.rs")
val requiredAbis = listOf("arm64-v8a", "x86_64") // 真机 + 模拟器（debug 最低集）

fun readContentHash(file: File, pattern: Regex): Int {
    if (!file.exists()) {
        throw GradleException("FRB 生成文件不存在: ${file.absolutePath}")
    }
    val match = pattern.find(file.readText())
        ?: throw GradleException("无法从 ${file.name} 解析 content hash")
    return match.groupValues[1].toInt()
}

fun soEmbedsHash(soFile: File, hash: Int): Boolean {
    if (!soFile.exists()) return false
    val needle = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(hash).array()
    val bytes = Files.readAllBytes(soFile.toPath())
    outer@ for (i in 0..bytes.size - needle.size) {
        for (j in needle.indices) {
            if (bytes[i + j] != needle[j]) continue@outer
        }
        return true
    }
    return false
}

fun readMetaHash(soFile: File): Int? {
    val metaFile = File(soFile.parentFile, "${soFile.name}.meta")
    if (!metaFile.exists()) return null
    val text = metaFile.readText()
    val match = Regex(""""contentHash"\s*:\s*(-?\d+)""").find(text) ?: return null
    return match.groupValues[1].toInt()
}

tasks.register("verifyRustFfiLibs") {
    group = "legado"
    description = "Verify Android jniLibs match FRB content hash"

    doLast {
        if (System.getenv("LEGADO_SKIP_RUST_BUILD") == "1") {
            logger.lifecycle("[Legado] LEGADO_SKIP_RUST_BUILD=1，跳过 Rust FFI 校验")
            return@doLast
        }

        val dartHash = readContentHash(
            dartFrbFile,
            Regex("""rustContentHash\s*=>\s*(-?\d+)""")
        )
        val rustHash = readContentHash(
            rustFrbFile,
            Regex("""FLUTTER_RUST_BRIDGE_CODEGEN_CONTENT_HASH:\s*i32\s*=\s*(-?\d+)""")
        )
        if (dartHash != rustHash) {
            throw GradleException(
                "Dart/Rust frb_generated content hash 不一致（Dart=$dartHash Rust=$rustHash）。" +
                    "请先运行 flutter_legado/scripts/generate-bridge.ps1"
            )
        }

        val issues = mutableListOf<String>()
        for (abi in requiredAbis) {
            val soFile = File(jniLibsDir, "$abi/liblegado_ffi.so")
            if (!soFile.exists()) {
                issues.add("缺少 $abi/liblegado_ffi.so")
                continue
            }
            val metaHash = readMetaHash(soFile)
            when {
                metaHash != null && metaHash == dartHash ->
                    logger.lifecycle("[Legado] FFI OK: $abi（meta hash=$dartHash）")
                metaHash != null ->
                    issues.add("$abi .so.meta hash=$metaHash，期望 $dartHash")
                soEmbedsHash(soFile, dartHash) ->
                    logger.lifecycle("[Legado] FFI OK: $abi（二进制 hash 校验）")
                else ->
                    issues.add("$abi liblegado_ffi.so 与当前 FRB hash $dartHash 不同步")
            }
        }

        if (issues.isEmpty()) return@doLast

        val buildMode = if (gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }) {
            "release"
        } else {
            "debug"
        }
        val buildCmd = when {
            System.getProperty("os.name").lowercase().contains("windows") ->
                ".\\rust\\scripts\\build-android.ps1 -Mode $buildMode -Targets \"aarch64,x86_64\""
            else ->
                "cd rust && ./scripts/build-android.sh $buildMode"
        }

        throw GradleException(
            """
            |
            |=== Legado Rust FFI 未同步（将导致「引擎初始化失败」）===
            |${issues.joinToString("\n") { "  - $it" }}
            |
            |请执行（仓库根目录）：
            |  $buildCmd
            |
            |或统一入口：
            |  .\flutter_legado\scripts\build-apk.ps1
            |
            |纯 Dart UI 开发（无需 Rust）：
            |  flutter run --dart-define=USE_MOCK=true
            |
            |临时跳过校验（不推荐）：
            |  set LEGADO_SKIP_RUST_BUILD=1
            """.trimMargin()
        )
    }
}

tasks.matching { it.name == "preBuild" }.configureEach {
    dependsOn("verifyRustFfiLibs")
}
