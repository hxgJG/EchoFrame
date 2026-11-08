package com.hxg.lumio

import org.junit.Assert.*
import org.junit.Test

class LumioPlaybackSourceTest {
    @Test fun recognizesExistingScannedRecords() {
        assertEquals(42L, scannedMediaId("android-video-42", "video"))
        assertEquals(7L, scannedMediaId("android-audio-7", "audio"))
    }

    @Test fun neverTreatsOtherSourcesAsScannedMedia() {
        for (id in listOf("transfer-42", "macos-video-42", "android-audio-42",
            "android-video--1", "android-video-0", "android-video-42/other",
            "android-video-999999999999999999999")) {
            assertNull(scannedMediaId(id, "video"))
        }
        assertNull(scannedMediaId("android-image-42", "image"))
    }
}
