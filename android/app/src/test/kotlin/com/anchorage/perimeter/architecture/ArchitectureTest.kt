package com.anchorage.perimeter.architecture

import com.google.common.truth.Truth.assertWithMessage
import java.io.File
import org.junit.Test

/**
 * Guards the dependency rule now that it is no longer a compiler invariant.
 *
 * While `domain` and `core/common` were separate `kotlin-jvm` Gradle modules,
 * an `import android.*` in a use case simply would not compile. Collapsing to
 * one module buys a single build file at the cost of that guarantee, so the
 * rule is re-stated here as a test that reads the sources and fails on the
 * first violation.
 *
 * This is a real trade: a test can be deleted where a missing dependency
 * cannot. It is kept honest by [`the scan actually reaches the source tree`],
 * which fails if the file walk finds nothing — without it, every rule below
 * would pass vacuously the moment the layout moved.
 *
 * The rules, one test each:
 *  1. `domain` imports no Android, Play Services or DI framework.
 *  2. `domain` imports nothing from an outer layer.
 *  3. `core/common` stays framework-free for the same reason `domain` does.
 *  4. `presentation` never reaches past `domain` into `data`.
 *  5. `data` never reaches up into `presentation`.
 */
class ArchitectureTest {

    @Test
    fun `the scan actually reaches the source tree`() {
        // Every other assertion in this file is "no violations found". If the
        // walk silently returned nothing they would all pass while proving
        // nothing, so the fixture asserts its own reach first.
        assertWithMessage("architecture scan found no Kotlin sources under $sourceRoot")
            .that(importsIn("domain").size)
            .isGreaterThan(20)
    }

    @Test
    fun `the domain layer does not import the Android framework`() {
        assertNoImports(
            layer = "domain",
            forbidden = FRAMEWORK_PACKAGES,
            because = "domain rules must stay unit-testable on the JVM with no device or stub",
        )
    }

    @Test
    fun `the domain layer does not import an outer layer`() {
        assertNoImports(
            layer = "domain",
            forbidden = listOf(
                "$ROOT.data",
                "$ROOT.presentation",
                "$ROOT.di",
                "$ROOT.core.designsystem",
            ),
            because = "dependencies point inward; the domain declares ports, it does not consume adapters",
        )
    }

    @Test
    fun `core common stays framework-free`() {
        assertNoImports(
            layer = "core/common",
            forbidden = FRAMEWORK_PACKAGES,
            because = "Outcome and AppError are shared by the domain, so they inherit its purity rule",
        )
    }

    @Test
    fun `the presentation layer does not reach into the data layer`() {
        assertNoImports(
            layer = "presentation",
            forbidden = listOf("$ROOT.data"),
            because = "state holders talk to use cases and ports; Hilt substitutes the adapter in di/",
        )
    }

    @Test
    fun `the data layer does not reach into the presentation layer`() {
        assertNoImports(
            layer = "data",
            forbidden = listOf("$ROOT.presentation"),
            because = "an adapter that knows about a screen cannot be reused or tested in isolation",
        )
    }

    // --- fixture ------------------------------------------------------------

    private data class Import(val file: File, val statement: String)

    private fun assertNoImports(layer: String, forbidden: List<String>, because: String) {
        val violations = importsIn(layer)
            .filter { import -> forbidden.any { import.statement.startsWith(it) } }
            .map { "${it.file.name}: import ${it.statement}" }
            .sorted()

        assertWithMessage("$layer/ must not import ${forbidden.joinToString()} — $because")
            .that(violations)
            .isEmpty()
    }

    private fun importsIn(layer: String): List<Import> =
        File(sourceRoot, layer).walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .flatMap { file ->
                file.readLines()
                    .filter { it.startsWith("import ") }
                    .map { Import(file, it.removePrefix("import ").substringBefore(" as ").trim()) }
                    .asSequence()
            }
            .toList()

    private companion object {
        const val ROOT = "com.anchorage.perimeter"

        val FRAMEWORK_PACKAGES = listOf(
            "android.",
            "androidx.",
            "com.google.android.",
            "dagger.",
            "javax.inject.",
        )

        /**
         * Resolved by walking up from the working directory rather than
         * hard-coded, so the test survives being run from the module dir
         * (Gradle) or the repository root (an IDE run configuration).
         */
        val sourceRoot: File = run {
            val relative = "src/main/kotlin/com/anchorage/perimeter"
            val workingDir = System.getProperty("user.dir") ?: "."
            generateSequence(File(workingDir).absoluteFile) { it.parentFile }
                .flatMap { sequenceOf(File(it, relative), File(it, "app/$relative")) }
                .firstOrNull { it.isDirectory }
                ?: error("Could not locate $relative from $workingDir")
        }
    }
}
