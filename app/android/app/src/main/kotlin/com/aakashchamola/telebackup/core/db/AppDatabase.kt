package com.aakashchamola.telebackup.core.db

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import java.io.File

/**
 * The one database (docs/DATA_MODEL.md). Lives in the no-backup folder, schema exported to app/schemas/.
 * There is no destructive fallback: losing the database would lose which files are already backed up.
 * The partial unique index on live rule names is enforced by RuleRepository (Room cannot express it).
 */
@Database(
    entities = [RuleEntity::class, TopicEntity::class, FileEntity::class, ReviewEntity::class, EventEntity::class, SettingEntity::class],
    version = 3,
    exportSchema = true,
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun ruleDao(): RuleDao
    abstract fun topicDao(): TopicDao
    abstract fun fileDao(): FileDao
    abstract fun reviewDao(): ReviewDao
    abstract fun eventDao(): EventDao
    abstract fun settingDao(): SettingDao

    companion object {
        const val FILE_NAME = "telebackup.db"

        /** 2: files.topicId (a topic of the file's own, for documents) and rules.sortDocuments (off for every existing rule). */
        /** 3: files.partCount (1 for every existing file). */
        val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE files ADD COLUMN partCount INTEGER NOT NULL DEFAULT 1")
            }
        }

        val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE files ADD COLUMN topicId INTEGER")
                db.execSQL("ALTER TABLE rules ADD COLUMN sortDocuments INTEGER NOT NULL DEFAULT 0")
            }
        }

        fun open(context: Context): AppDatabase =
            Room.databaseBuilder(context, AppDatabase::class.java, File(context.noBackupFilesDir, FILE_NAME).absolutePath)
                .setJournalMode(RoomDatabase.JournalMode.WRITE_AHEAD_LOGGING)
                .addMigrations(MIGRATION_1_2, MIGRATION_2_3)
                .build()
    }
}
