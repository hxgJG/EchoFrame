package com.hxg.lumio

fun main() {
    val original = mapOf<String, Any?>("path" to "/Music/黄凯芹 - 晚秋.mp3",
        "title" to "ÍíÇï", "artist" to "»Æ¿­ÇÛ", "album" to "±¦Àö½ð", "playCount" to 7)
    val repaired = LumioMetadataRepair.record(original)
    check(repaired["title"] == "晚秋" && repaired["artist"] == "黄凯芹" && repaired["album"] == "宝丽金")
    check(repaired["playCount"] == 7 && LumioMetadataRepair.record(repaired) == repaired)
    for (title in listOf("Café", "Beyoncé", "Voilà déjà", "Mötley Crüe", "晚秋", "hello", "😀", "ÿÿÿÿ")) {
        check(LumioMetadataRepair.record(mapOf("path" to "/Music/晚秋.mp3", "title" to title))["title"] == title)
    }
    check(LumioMetadataRepair.record(original + ("path" to "/Music/track01.mp3"))["title"] == "ÍíÇï")
    val restored = LumioMetadataRepair.library(mapOf("audioItems" to listOf(original), "themeMode" to "dark"))
    check(((restored["audioItems"] as List<*>).first() as Map<*, *>)["title"] == "晚秋")
    check(restored["themeMode"] == "dark")
    println("Metadata repair checks passed")
}
