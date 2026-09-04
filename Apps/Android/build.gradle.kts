plugins {
    id("com.android.application")
    id("com.google.devtools.ksp")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

val publicSupabaseUrl = providers.gradleProperty("FO_PUBLIC_SUPABASE_URL").orNull.orEmpty().trim()
val publicSupabaseKey = providers.gradleProperty("FO_PUBLIC_SUPABASE_KEY").orNull.orEmpty().trim()
val publicGoogleClientId = providers.gradleProperty("FO_PUBLIC_GOOGLE_CLIENT_ID").orNull.orEmpty().trim()

fun buildConfigString(value: String): String = "\"${value.replace("\\", "\\\\").replace("\"", "\\\"")}\""

android {
    namespace = "com.foundersoffice.openloops"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.foundersoffice.openloops"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0-dev"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // These are public client values only. By default they are blank, which
        // keeps product auth and remote sync disabled. Do not add any secret.
        buildConfigField("String", "PUBLIC_SUPABASE_URL", buildConfigString(publicSupabaseUrl))
        buildConfigField("String", "PUBLIC_SUPABASE_KEY", buildConfigString(publicSupabaseKey))
        buildConfigField("String", "PUBLIC_GOOGLE_CLIENT_ID", buildConfigString(publicGoogleClientId))
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            // Android's debug keystore is generated under the developer's home
            // directory. It is intentionally never copied into this repository.
        }
        release {
            isMinifyEnabled = false
            // A signed beta/release configuration is deliberately not present.
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
    implementation("androidx.glance:glance-appwidget:1.1.1")
    implementation("androidx.glance:glance-material3:1.1.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.room:room-ktx:2.6.1")
    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("androidx.work:work-runtime-ktx:2.10.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    ksp("androidx.room:room-compiler:2.6.1")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlin:kotlin-test-junit:2.0.21")
}
