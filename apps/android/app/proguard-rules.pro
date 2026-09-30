# kotlinx.serialization keeps generated serializers via its bundled consumer rules.
-keepattributes *Annotation*, InnerClasses

# SQLCipher is reached through JNI; keep its classes and native method names.
-keep class net.zetetic.database.** { *; }
-keepclasseswithmembernames class * { native <methods>; }

# LiteRT-LM calls back from native code into its Kotlin classes (message and inference callbacks) and ships no
# consumer rules; keep the package intact so the release build behaves like the tested debug build.
-keep class com.google.ai.edge.litertlm.** { *; }
-dontwarn com.google.ai.edge.litertlm.**
