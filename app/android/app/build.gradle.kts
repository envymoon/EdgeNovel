import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.FileSystemOperations
import org.gradle.api.tasks.InputDirectory
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.TaskAction
import javax.inject.Inject

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

abstract class StageEdgeEngineTask : DefaultTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val nativeDirectory: DirectoryProperty

    @get:OutputDirectory
    abstract val destinationDirectory: DirectoryProperty

    @get:Inject
    abstract val fileSystemOperations: FileSystemOperations

    @TaskAction
    fun stage() {
        for (abi in listOf("arm64-v8a", "x86_64")) {
            check(nativeDirectory.file("$abi/libedge_llama_server.so").get().asFile.isFile) {
                "Missing freshly built Android engine for $abi"
            }
        }
        fileSystemOperations.sync {
            from(nativeDirectory)
            include("arm64-v8a/libedge_llama_server.so", "x86_64/libedge_llama_server.so")
            into(destinationDirectory)
        }
    }
}

android {
    namespace = "com.novel.novel"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.novel.novel"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // The local database/AI bridge is compiled for modern 64-bit phones.
        // x86_64 is retained so development can continue in an emulator without
        // owning an Android handset.
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
        externalNativeBuild {
            cmake {
                abiFilters += listOf("arm64-v8a", "x86_64")
                targets += "edge_llama_server"
                arguments += listOf(
                    "-DANDROID_STL=c++_static",
                    "-DEDGE_ENGINE_OUTPUT_DIR=${layout.buildDirectory.get().asFile}/native-engine-output",
                    "-DEDGE_LLAMA_ARCHIVE=${rootProject.layout.buildDirectory.get().asFile}/native-engine-source/llama-c4ae9a88.tar.gz",
                )
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
            buildStagingDirectory = rootProject.layout.buildDirectory.dir("native-engine-cmake").get().asFile
        }
    }
    packaging {
        jniLibs {
            // Android 10+ disallows executing downloads in writable app data.
            // PackageManager must extract the signed APK's native executable.
            useLegacyPackaging = true
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

androidComponents {
    onVariants(selector().all()) { variant ->
        val capitalized = variant.name.replaceFirstChar { it.uppercase() }
        val cmakeType = variant.buildType
        val stageEngine = tasks.register<StageEdgeEngineTask>("stage${capitalized}AiEngine") {
            dependsOn("externalNativeBuild$capitalized")
            nativeDirectory.set(layout.buildDirectory.dir("native-engine-output/$cmakeType"))
            // CMake is an external writer. Explicit staging avoids AGP's VFS
            // snapshot reusing yesterday's executable after a native rebuild.
            outputs.upToDateWhen { false }
        }
        // Register through the variant API, as Flutter does for libapp.so.
        // Mutating legacy sourceSets here is too late for AGP's JNI snapshot.
        variant.sources.jniLibs?.addGeneratedSourceDirectory(
            stageEngine, StageEdgeEngineTask::destinationDirectory
        )
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
