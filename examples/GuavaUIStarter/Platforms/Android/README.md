Open this directory in Android Studio. app/src/main owns this app's manifest, native resources and Java/Kotlin extensions.
The framework host and SDL stay in the SDK and are referenced by Gradle, not copied into your app.
Common application identity/version come from guava.json. Add native dependencies to app/build.gradle.kts.
The preBuild task asks guava to prepare Swift libraries/assets. Gradle then performs standard resource processing, manifest merging and APK packaging.
