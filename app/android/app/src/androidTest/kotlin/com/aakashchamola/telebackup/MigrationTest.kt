package com.aakashchamola.telebackup

import androidx.room.testing.MigrationTestHelper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.aakashchamola.telebackup.core.db.AppDatabase
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Every Room migration is tested from every older schema (docs/DATA_MODEL.md "Migrations").
 * Version 1 must open and keep its rows, and every later version must be reached from it with nothing lost.
 */
@RunWith(AndroidJUnit4::class)
class MigrationTest {
    @get:Rule
    val helper = MigrationTestHelper(InstrumentationRegistry.getInstrumentation(), AppDatabase::class.java)

    @Test
    fun version1OpensAndKeepsItsRows() {
        helper.createDatabase("migration-test", 1).apply {
            execSQL("INSERT INTO settings(`key`, value) VALUES('app.setupStep', 'O3')")
            close()
        }
        val db = helper.runMigrationsAndValidate("migration-test", 1, true)
        db.query("SELECT value FROM settings WHERE `key` = 'app.setupStep'").use {
            check(it.moveToFirst() && it.getString(0) == "O3")
        }
    }

    @Test
    fun version1MigratesTo2KeepingRowsAndAddingTheNewColumns() {
        helper.createDatabase("migration-test-2", 1).apply {
            execSQL("INSERT INTO settings(`key`, value) VALUES('telegram.chatId', '-1001')")
            execSQL(
                "INSERT INTO rules(name, folderPath, includeSubfolders, mediaTypes, uploadAs, mode, retentionDays, startMode, enabled, dryRun, createdAt, updatedAt) " +
                    "VALUES('Old rule', 'DCIM/Camera/', 0, 'BOTH', 'MEDIA', 'UPLOAD_ONLY', 7, 'TODAY', 1, 1, 1, 1)",
            )
            close()
        }
        val db = helper.runMigrationsAndValidate("migration-test-2", 2, true, AppDatabase.MIGRATION_1_2)
        db.query("SELECT value FROM settings WHERE `key` = 'telegram.chatId'").use { check(it.moveToFirst() && it.getString(0) == "-1001") }
        // an old rule keeps working and has document sorting off
        db.query("SELECT name, sortDocuments FROM rules").use { check(it.moveToFirst() && it.getString(0) == "Old rule" && it.getInt(1) == 0) }
        db.query("PRAGMA table_info(files)").use { c ->
            val names = generateSequence { if (c.moveToNext()) c.getString(c.getColumnIndexOrThrow("name")) else null }.toList()
            check("topicId" in names) { "files.topicId missing: $names" }
        }
    }
}
