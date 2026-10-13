plugins { id("com.android.library") }

layout.buildDirectory.set(rootProject.projectDir.resolve("../../.guava/build/android/gradle/runtime"))
android {
    namespace = "com.guava.runtime"
    compileSdk = 36
    defaultConfig { minSdk = 28 }
    buildTypes { create("profile") { initWith(getByName("release")) } }
    sourceSets.getByName("main") {
        manifest.srcFile("../App/AndroidManifest.xml")
        java.srcDir("../App/src")
        java.srcDir("../../../Engine/third-party/sdl3/android-project/app/src/main/java")
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_1_8; targetCompatibility = JavaVersion.VERSION_1_8 }
}
