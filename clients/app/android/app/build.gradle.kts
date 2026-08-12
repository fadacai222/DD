plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

val requireProductionSigning =
    providers.environmentVariable("DD_ANDROID_REQUIRE_PROD_SIGNING").orNull == "true"
val productionKeystorePath = providers.environmentVariable("DD_ANDROID_KEYSTORE_PATH").orNull
val productionKeystorePassword = providers.environmentVariable("DD_ANDROID_KEYSTORE_PASSWORD").orNull
val productionKeyAlias = providers.environmentVariable("DD_ANDROID_KEY_ALIAS").orNull
val productionKeyPassword = providers.environmentVariable("DD_ANDROID_KEY_PASSWORD").orNull
val productionSigningReady = listOf(
    productionKeystorePath,
    productionKeystorePassword,
    productionKeyAlias,
    productionKeyPassword,
).all { !it.isNullOrBlank() }

android {
    namespace = "org.openimx.client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "org.openimx.client"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    signingConfigs {
        if (productionSigningReady) {
            create("production") {
                storeFile = file(productionKeystorePath!!)
                storePassword = productionKeystorePassword
                keyAlias = productionKeyAlias
                keyPassword = productionKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = when {
                productionSigningReady -> signingConfigs.getByName("production")
                requireProductionSigning -> throw GradleException(
                    "DD production Android signing is required, but one or more " +
                        "DD_ANDROID_KEYSTORE_PATH/DD_ANDROID_KEYSTORE_PASSWORD/" +
                        "DD_ANDROID_KEY_ALIAS/DD_ANDROID_KEY_PASSWORD values are missing."
                )
                else -> signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
