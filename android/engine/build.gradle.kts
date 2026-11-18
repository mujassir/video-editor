plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "com.mujassir.cutline.engine"
    compileSdk = 36
    defaultConfig { minSdk = 26 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    testOptions {
        unitTests.isIncludeAndroidResources = true
        unitTests.all {
            // Prefer Maven Central for Robolectric's android-all jars (CI can miss Google's mirror).
            it.systemProperty("robolectric.dependency.repo.url", "https://repo1.maven.org/maven2")
            it.systemProperty("robolectric.dependency.repo.id", "central")
        }
    }
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

dependencies {
    api(project(":core"))
    api(libs.media3.transformer)
    api(libs.media3.effect)
    api(libs.media3.exoplayer)
    api(libs.media3.common)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.exifinterface)
    implementation(libs.kotlinx.coroutines.android)
    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
}
