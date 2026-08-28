# Room + Hilt + Compose ship their own consumer rules; keep only what the app
# reflects on directly.
-keepattributes *Annotation*
-keep class com.anchorage.perimeter.core.data.local.entity.** { *; }
