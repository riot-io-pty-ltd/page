# Page keeps no reflection-based serialisation: JSON is read through
# kotlinx.serialization's JsonElement tree, so no model classes need keeping.

# OkHttp ships its own consumer rules; these silence optional platform hooks.
-dontwarn org.bouncycastle.jsse.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
