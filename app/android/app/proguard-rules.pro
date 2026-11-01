# teleBackup release rules (docs/phases/M7.md)

# The Flutter <-> Kotlin bridge is called by name from generated code.
-keep class com.aakashchamola.telebackup.bridge.** { *; }

# kotlinx-serialization: keep the generated serializers of our @Serializable classes (rules export file).
-keepattributes *Annotation*, InnerClasses, Signature, RuntimeVisibleAnnotations
-keepclassmembers class com.aakashchamola.telebackup.core.rules.** {
    *** Companion;
}
-keepclasseswithmembers class com.aakashchamola.telebackup.core.rules.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.aakashchamola.telebackup.core.rules.**$$serializer { *; }

# Workers are created by WorkManager from their class name.
-keep class com.aakashchamola.telebackup.core.work.** { *; }
-keep class com.aakashchamola.telebackup.core.notify.ControlReceiver { *; }

# TDLib (when the account path is added): called from native code.
-keep class org.drinkless.tdlib.** { *; }

-dontwarn org.slf4j.**
-dontwarn javax.annotation.**
