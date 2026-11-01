package com.aakashchamola.telebackup.core.db

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import java.io.File

/**
 * The one database (docs/DATA_MODEL.md). Lives in the no-backup folder, schema exported to app/schemas/.
 * There is no destructive fallback: losing the database would lose which files are already backed up.
 * The partial unique index on live rule names is enforced by RuleRepository (Room cannot express it).
 */
@Database(
    entities = [RuleEntity::class, TopicEntity::class, FileEntity::class, ReviewEntity::class, EventEntity::class, SettingEntity::class],
    version = 1,
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

        fun open(context: Context): AppDatabase =
            Room.databaseBuilder(context, AppDatabase::class.java, File(context.noBackupFilesDir, FILE_NAME).absolutePath)
                .setJournalMode(RoomDatabase.JournalMode.WRITE_AHEAD_LOGGING)
                .build()
    }
}
