plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "org.nexo.bridge"
    compileSdk = 35

    defaultConfig {
        applicationId = "org.nexo.bridge"
        minSdk = 26

        // targetSdk = 28 A PROPÓSITO (igual que Termux).
        // Android 10+ le quita a las apps que apuntan a 29 o más la posibilidad de
        // encender/apagar el WiFi, conectarse a redes, leer el nombre del WiFi desde un
        // servicio en segundo plano, etc. Con 28 la app puede hacerlo directamente; si el
        // sistema se lo niega, la app lo detecta y te lo pide con una notificación.
        // Como no se publica en Google Play, no hay obligación de apuntar más alto.
        targetSdk = 28

        versionCode = 1
        versionName = "0.1.0"
    }

    // Archivos que viajan dentro del APK como assets: el cliente y el instalador de Termux.
    // Así la app puede instalarlos en Termux sin internet (ver Bootstrap.kt).
    sourceSets {
        getByName("main") {
            assets.srcDir(file("$rootDir/../termux"))
        }
    }

    signingConfigs {
        // Firma estable opcional: si defines estas variables de entorno (o los secretos de
        // GitHub que usa el workflow) todas las compilaciones se firman con la misma clave
        // y se pueden instalar encima de la anterior. Si no, se firma con la clave de depuración.
        val ksPath = System.getenv("NEXO_KEYSTORE")
        if (!ksPath.isNullOrEmpty()) {
            create("nexo") {
                storeFile = file(ksPath)
                storePassword = System.getenv("NEXO_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("NEXO_KEY_ALIAS")
                keyPassword = System.getenv("NEXO_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("nexo") ?: signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    lint {
        // targetSdk bajo es intencional; no queremos que lint rompa la compilación por eso.
        abortOnError = false
        checkReleaseBuilds = false
    }
}

// Sin librerías de terceros a propósito: solo el framework de Android y la stdlib de Kotlin.
dependencies {
}
