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

tasks.test {
    systemProperty("vetmed.shared", rootDir.resolve("../../shared").absolutePath)
    // Rewrites the shared backup fixture read by the iOS tests (ADR 0019); only on purpose.
    providers.systemProperty("vetmed.writeBackupFixture").orNull?.let { systemProperty("vetmed.writeBackupFixture", it) }
}
