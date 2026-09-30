plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

kotlin { jvmToolchain(21) }

// Prompts are shared with iOS; the fixtures stay test-only.
sourceSets.main { resources.srcDir("../../../shared/prompts") }

dependencies {
    api(libs.kotlinx.serialization.json)
    api(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}

tasks.test { systemProperty("vetmed.shared", rootDir.resolve("../../shared").absolutePath) }
