# Flutter
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Deferred Components / Play Core
-dontwarn com.google.android.play.core.**

# Google ML Kit
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**
-keep class com.google_mlkit_commons.** { *; }
-dontwarn com.google_mlkit_commons.**
-keep class com.google_mlkit_translation.** { *; }
-dontwarn com.google_mlkit_translation.**

# Keep all ComponentRegistrars for ML Kit internal initialization
-keep public class * implements com.google.firebase.components.ComponentRegistrar {
    public <init>();
}
-keep public class * extends com.google.firebase.components.ComponentRegistrar {
    public <init>();
}
