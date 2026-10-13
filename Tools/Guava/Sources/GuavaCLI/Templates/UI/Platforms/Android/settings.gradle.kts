import groovy.json.JsonSlurper

pluginManagement {
    val androidPluginVersion = "8.11.1"
    repositories { google(); mavenCentral(); gradlePluginPortal() }
    plugins {
        id("com.android.application") version androidPluginVersion
        id("com.android.library") version androidPluginVersion
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "GuavaApplication"
val projectRoot = rootDir.resolve("../..").canonicalFile
val manifest = JsonSlurper().parse(projectRoot.resolve("guava.json")) as Map<*, *>
val toolchain = manifest["toolchain"] as Map<*, *>
val engine = System.getenv("GUAVA_ENGINE_ROOT")?.let(::File)
    ?: projectRoot.resolve(toolchain["enginePath"] as String).canonicalFile
include(":app", ":guavaRuntime")
project(":guavaRuntime").projectDir = engine.resolve("Platforms/Android/Runtime")
