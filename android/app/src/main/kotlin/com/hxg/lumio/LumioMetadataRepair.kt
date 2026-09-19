package com.hxg.lumio

import java.io.File
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction

/** Only repair reversible legacy Chinese tags corroborated by the filename. */
internal object LumioMetadataRepair {
    fun record(original: Map<String, Any?>): Map<String, Any?> {
        val path = original["path"] as? String ?: return original
        val filename = File(path).nameWithoutExtension
        val candidates = listOf("title", "artist", "album").mapNotNull { field ->
            val value = original[field] as? String ?: return@mapNotNull null
            candidate(value)?.let { field to it }
        }.toMap()
        if (listOf("title", "artist").none { candidates[it]?.let(filename::contains) == true }) {
            return original
        }
        return original + candidates
    }

    fun library(original: Map<String, Any?>): Map<String, Any?> {
        val result = original.toMutableMap()
        for (key in listOf("audioItems", "videoItems")) {
            val items = original[key] as? List<*> ?: continue
            result[key] = items.map { item ->
                if (item is Map<*, *> && item.keys.all { it is String }) {
                    @Suppress("UNCHECKED_CAST")
                    record(item as Map<String, Any?>)
                } else item
            }
        }
        return result
    }

    private fun candidate(value: String): String? {
        if (value.length < 4 || value.any { isChinese(it) } ||
            value.count { it.code >= 0x80 } * 2 < value.length) return null
        val chinese = Charset.forName("GB18030")
        for (encoding in listOf(Charsets.ISO_8859_1, Charset.forName("windows-1252"))) {
            try {
                val bytes = encode(value, encoding)
                if (decode(bytes, encoding) != value) continue
                val decoded = decode(bytes, chinese)
                if (!encode(decoded, chinese).contentEquals(bytes)) continue
                val count = decoded.count { isChinese(it) }
                if (count >= 2 && count * 2 >= decoded.length &&
                    decoded.none { it.isISOControl() || it == '\uFFFD' }) return decoded
            } catch (_: java.nio.charset.CharacterCodingException) {
                // 不可逆或无效字节不做修复。
            }
        }
        return null
    }

    private fun encode(value: String, charset: Charset): ByteArray {
        val buffer = charset.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).encode(CharBuffer.wrap(value))
        return ByteArray(buffer.remaining()).also { buffer.get(it) }
    }

    private fun decode(bytes: ByteArray, charset: Charset): String = charset.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(bytes)).toString()

    private fun isChinese(char: Char) = char.code in 0x3400..0x4DBF || char.code in 0x4E00..0x9FFF
}
