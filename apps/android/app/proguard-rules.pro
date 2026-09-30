# kotlinx.serialization keeps generated serializers via its bundled consumer rules.
-keepattributes *Annotation*, InnerClasses

# SQLCipher is reached through JNI; keep its classes and native method names.
-keep class net.zetetic.database.** { *; }
-keepclasseswithmembernames class * { native <methods>; }
