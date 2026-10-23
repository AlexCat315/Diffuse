import groovy.json.JsonSlurper

plugins { id("com.android.application") }

val projectRoot = rootProject.projectDir.resolve("../..").canonicalFile
val configuration = JsonSlurper().parse(projectRoot.resolve("guava.json")) as Map<*, *>
val application = configuration["application"] as Map<*, *>
val version = configuration["version"] as Map<*, *>
val sdk = extensions.extraProperties["guavaSDK"] as File
val generated = projectRoot.resolve(".guava/build/android/generated")
layout.buildDirectory.set(projectRoot.resolve(".guava/build/android/gradle/app"))
rootProject.layout.buildDirectory.set(projectRoot.resolve(".guava/build/android/gradle/root"))

android {
    namespace = "com.guava.probe"
    compileSdk = 36
    buildToolsVersion = "36.1.0"
    defaultConfig {
        applicationId = application["id"] as String
        minSdk = 28
        targetSdk = 36
        versionCode = (version["build"] as Number).toInt()
        versionName = version["name"] as String
        manifestPlaceholders["applicationName"] = application["name"] as String
        ndk { abiFilters += "arm64-v8a" }
    }
    val cliSigning = providers.gradleProperty("guavaKeystore").orNull?.let { path ->
        signingConfigs.create("guavaCLI") {
            storeFile = file(path)
            keyAlias = providers.gradleProperty("guavaKeyAlias").get()
            storePassword = System.getenv(providers.gradleProperty("guavaStorePasswordEnv").get())
            keyPassword = System.getenv(providers.gradleProperty("guavaKeyPasswordEnv").get())
        }
    }
    buildTypes {
        getByName("debug") { if (cliSigning != null) signingConfig = cliSigning }
        getByName("release") { isMinifyEnabled = false; if (cliSigning != null) signingConfig = cliSigning }
        create("profile") {
            initWith(getByName("release"))
            isDebuggable = true
            matchingFallbacks += "release"
        }
    }
    listOf("debug", "profile", "release").forEach { mode ->
        sourceSets.getByName(mode) {
            assets.srcDir(generated.resolve("$mode/assets"))
            jniLibs.srcDir(generated.resolve("$mode/lib"))
        }
    }
    packaging { jniLibs { useLegacyPackaging = true; keepDebugSymbols += "**/*.so" } }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_1_8; targetCompatibility = JavaVersion.VERSION_1_8 }
}

dependencies { implementation(project(":guavaRuntime")) }

// Android Studio and Gradle use the same Swift preparation step as the CLI.
listOf("debug", "profile", "release").forEach { mode ->
    val suffix = mode.replaceFirstChar { it.uppercaseChar() }
    val prepareGuava = tasks.register<Exec>("prepareGuava$suffix") {
        onlyIf { !providers.gradleProperty("guavaPrepared").isPresent }
        workingDir(projectRoot)
        commandLine(sdk.resolve(if (System.getProperty("os.name").startsWith("Windows")) "guava.cmd" else "guava").path,
            "internal", "android-prepare", projectRoot.path, "--$mode")
    }
    tasks.matching { it.name == "pre${suffix}Build" }.configureEach { dependsOn(prepareGuava) }
}
