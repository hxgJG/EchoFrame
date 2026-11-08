package com.hxg.lumio

internal fun scannedMediaId(mediaId: String, kind: String): Long? {
    if (kind != "audio" && kind != "video") return null
    val prefix = "android-$kind-"
    if (!mediaId.startsWith(prefix)) return null
    val suffix = mediaId.removePrefix(prefix)
    if (!suffix.matches(Regex("[0-9]+"))) return null
    return suffix.toLongOrNull()?.takeIf { it > 0 }
}
