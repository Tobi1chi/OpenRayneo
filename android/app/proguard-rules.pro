# Copyright 2026 Tobi1chi
# SPDX-License-Identifier: Apache-2.0

-keepattributes SourceFile,LineNumberTable

# Silence optional TLS providers referenced by OkHttp on JVM platforms.
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
