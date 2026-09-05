plugins {
    id("com.android.application")
    id("com.google.devtools.ksp")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

fun publicValue(name: String): String = providers.gradleProperty(name)
    .orElse(providers.environmentVariable(name))
    .orNull
    .orEmpty()
    .trim()

val publicSupabaseUrl = publicValue("FO_PUBLIC_SUPABASE_URL")
val publicSupabaseKey = publicValue("FO_PUBLIC_SUPABASE_KEY")
val publicGoogleClientId = publicValue("FO_PUBLIC_GOOGLE_CLIENT_ID")
val releaseKeystorePath = providers.environmentVariable("FO_ANDROID_UPLOAD_KEYSTORE_PATH").orNull.orEmpty().trim()
val releaseKeyAlias = providers.environmentVariable("FO_ANDROID_UPLOAD_KEY_ALIAS").orNull.orEmpty().trim()
val releaseStorePassword = providers.environmentVariable("FO_ANDROID_UPLOAD_STORE_PASSWORD").orNull.orEmpty()
val releaseKeyPassword = providers.environmentVariable("FO_ANDROID_UPLOAD_KEY_PASSWORD").orNull.orEmpty()
val releaseSigningConfigured = listOf(
    releaseKeystorePath,
    releaseKeyAlias,
    releaseStorePassword,
    releaseKeyPassword
).all(String::isNotBlank)

fun buildConfigString(value: String): String = "\"${value.replace("\\", "\\\\").replace("\"", "\\\"")}\""

android {
    namespace = "com.foundersoffice.openloops"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.foundersoffice.openloops"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // These are public client values only. By default they are blank, which
        // keeps product auth and remote sync disabled. Do not add any secret.
        buildConfigField("String", "PUBLIC_SUPABASE_URL", buildConfigString(publicSupabaseUrl))
        buildConfigField("String", "PUBLIC_SUPABASE_KEY", buildConfigString(publicSupabaseKey))
        buildConfigField("String", "PUBLIC_GOOGLE_CLIENT_ID", buildConfigString(publicGoogleClientId))
    }

    signingConfigs {
        if (releaseSigningConfigured) {
            create("release") {
                storeFile = file(releaseKeystorePath)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            // Android's debug keystore is generated under the developer's home
            // directory. It is intentionally never copied into this repository.
        }
        release {
            isDebuggable = false
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = signingConfigs.findByName("release")
        }
    }

    buildFeatures {
        buildConfig = true
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("test").resources.srcDir("../../Contracts/v1/fixtures")
    }

    testOptions {
        animationsDisabled = true
    }

    lint {
        abortOnError = true
        checkReleaseBuilds = true
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.activity:activity-compose:1.10.0")
    implementation("androidx.browser:browser:1.8.0")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.core:core-splashscreen:1.2.0")
    implementation("androidx.glance:glance-appwidget:1.1.1")
    implementation("androidx.glance:glance-material3:1.1.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.room:room-ktx:2.6.1")
    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.work:work-runtime-ktx:2.10.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    ksp("androidx.room:room-compiler:2.6.1")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlin:kotlin-test-junit:2.0.21")

    androidTestImplementation(platform("androidx.compose:compose-bom:2024.12.01"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.test:core-ktx:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}

val verifyAndroidReleaseReadiness = tasks.register("verifyAndroidReleaseReadiness") {
    group = "verification"
    description = "Fails closed unless public service configuration and upload signing are present."
    doLast {
        val missing = buildList {
            if (!publicSupabaseUrl.startsWith("https://")) add("FO_PUBLIC_SUPABASE_URL")
            if (publicSupabaseKey.isBlank()) add("FO_PUBLIC_SUPABASE_KEY")
            if (publicGoogleClientId.isBlank()) add("FO_PUBLIC_GOOGLE_CLIENT_ID")
            if (!releaseSigningConfigured) add("Android upload signing environment")
            if (releaseKeystorePath.isNotBlank() && !file(releaseKeystorePath).isFile) add("Android upload keystore file")
        }
        check(missing.isEmpty()) {
            "Android release is blocked. Missing or invalid: ${missing.joinToString()}."
        }
    }
}

tasks.matching { it.name == "assembleRelease" || it.name == "bundleRelease" }
    .configureEach { dependsOn(verifyAndroidReleaseReadiness) }
