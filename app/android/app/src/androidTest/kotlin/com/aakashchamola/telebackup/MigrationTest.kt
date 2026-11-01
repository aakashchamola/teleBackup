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
 * There is only version 1 today, so this proves the exported schema opens; add a test per migration from version 2 on.
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
}
