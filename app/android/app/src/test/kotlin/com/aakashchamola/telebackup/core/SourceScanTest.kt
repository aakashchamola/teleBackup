package com.aakashchamola.telebackup.core

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import java.io.File

/**
 * Plain string checks over the source, on purpose: the two doors must stay the only doors
 * (docs/TESTING.md). If one of these fails, a new call site was added in the wrong place.
 */
class SourceScanTest {
    private val root: File = generateSequence(File(System.getProperty("user.dir")).absoluteFile) { it.parentFile }
        .map { File(it, "src/main/kotlin") }.first { it.isDirectory }

    private fun mainFiles(): List<File> = root.walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()

    private fun code(f: File): String = f.readLines()
        .filterNot { val t = it.trim(); t.startsWith("//") || t.startsWith("*") || t.startsWith("/*") }
        .joinToString("\n")

    private fun rel(f: File) = f.relativeTo(root).invariantSeparatorsPath

    @Test fun deleteCallsOnlyInFileDeleter() {
        val forbidden = listOf(".delete(", "deleteRecursively", "createDeleteRequest", "Files.delete", "contentResolver.delete", "deleteIfExists")
        val offenders = mainFiles().filter { rel(it) != "com/aakashchamola/telebackup/core/clean/FileDeleter.kt" }
            .flatMap { f -> forbidden.filter { code(f).contains(it) }.map { "${rel(f)}: $it" } }
        assertThat(offenders).isEmpty()
        assertThat(mainFiles().any { rel(it).endsWith("clean/FileDeleter.kt") && code(it).contains(".delete(") }).isTrue()
    }

    @Test fun onlyTheGateMakesAPermit() {
        val offenders = mainFiles().filter { rel(it) != "com/aakashchamola/telebackup/core/model/DeleteGate.kt" }
            .filter { Regex("""GateResult\.Allowed\s*\(""").containsMatchIn(code(it)) }.map(::rel)
        assertThat(offenders).isEmpty()
    }

    @Test fun fileStateIsOnlyWrittenByTheMachine() {
        val allowed = setOf("com/aakashchamola/telebackup/core/model/FileStateMachine.kt")
        val bad = Regex("""\.copy\([^)]*\bstate\s*=|SET\s+state\b""", RegexOption.IGNORE_CASE)
        val offenders = mainFiles().filter { rel(it) !in allowed }.filter { bad.containsMatchIn(code(it)) }.map(::rel)
        assertThat(offenders).isEmpty()
    }

    @Test fun coreNeverImportsFlutterOrTheBridge() {
        val core = mainFiles().filter { rel(it).startsWith("com/aakashchamola/telebackup/core/") }
        val offenders = core.filter { Regex("""import\s+(io\.flutter|com\.aakashchamola\.telebackup\.bridge)""").containsMatchIn(it.readText()) }.map(::rel)
        assertThat(offenders).isEmpty()
    }

    @Test fun noPlainLoggingOrCurrentTimeInLogic() {
        // Tlog redacts; Clock is injected. android.util.Log only inside Tlog, currentTimeMillis only in the system clock.
        val logOffenders = mainFiles().filter { !rel(it).endsWith("log/Tlog.kt") }.filter { code(it).contains("android.util.Log") || Regex("""\bLog\.[dviwe]\(""").containsMatchIn(code(it)) }.map(::rel)
        assertThat(logOffenders).isEmpty()
        val timeOffenders = mainFiles().filter { !rel(it).endsWith("time/Clock.kt") }.filter { code(it).contains("currentTimeMillis") }.map(::rel)
        assertThat(timeOffenders).isEmpty()
    }
}
