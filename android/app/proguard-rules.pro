# Flutter ProGuard Rules
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Permission handler
-keep class com.baseflow.permissionhandler.** { *; }

# File picker
-keep class com.mr.flutter.plugin.filepicker.** { *; }

# Network info
-keep class dev.fluttercommunity.plus.network_info.** { *; }

# Google Play Core (SplitCompat)
-keep class com.google.android.play.** { *; }
-dontwarn com.google.android.play.**

# Keep all Dart classes
-keep class **.** { *; }
-dontwarn io.flutter.embedding.**
