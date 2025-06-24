plugins {
    id("com.android.library")
    id("kotlin-android")
}

val annotationVersion = "1.2.0"
val workVersion = "2.9.1"
val coreVersion = "1.6.0"
val media3Version = "1.4.1"
val kotlinVersion = "2.0.20"

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
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
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
    implementation("com.google.android.gms:play-services-cast-framework:21.5.0")
}
