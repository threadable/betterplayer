plugins {
    id("com.android.library")
    id("kotlin-android")
}

val annotationVersion = "1.10.0"
val workVersion = "2.11.1"
val media3Version = "1.10.0"
val kotlinVersion = "2.2.21"
val castFrameworkVersion = "22.3.0"

android {
    namespace = "com.jhomlala.better_player"
    compileSdk = 36

    defaultConfig {
        multiDexEnabled = true
        minSdk = 25
        targetSdk = 36
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    sourceSets["main"].java.srcDirs("src/main/kotlin")
}

repositories {
    google()
    mavenCentral()
}

dependencies {
    implementation("org.jetbrains.kotlin:kotlin-stdlib:$kotlinVersion")
    implementation("androidx.media3:media3-exoplayer:$media3Version")
    implementation("androidx.media3:media3-exoplayer-hls:$media3Version")
    implementation("androidx.media3:media3-exoplayer-dash:$media3Version")
    implementation("androidx.media3:media3-exoplayer-smoothstreaming:$media3Version")
    implementation("androidx.media3:media3-ui:$media3Version")
    implementation("androidx.media3:media3-session:$media3Version")
    implementation("androidx.annotation:annotation:$annotationVersion")
    implementation("androidx.work:work-runtime:$workVersion")
    implementation("com.google.android.gms:play-services-cast-framework:$castFrameworkVersion")
}
