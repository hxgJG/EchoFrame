package com.hxg.lumio

import org.junit.Assert.*
import org.junit.Test
import kotlin.math.*
import java.nio.ByteBuffer
import java.nio.ByteOrder
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor

class LumioSpectrumTest {
    private fun tone(frequency: Double, amplitude: Double = 0.5) =
        DoubleArray(1024) { amplitude * sin(2 * PI * frequency * it / 48000) }

    @Test fun amplitudesUseFixedLinearFullScale() {
        val frequency = 48000.0 * 10 / 1024
        for (amplitude in listOf(0.0, 0.005, 0.25, 0.5, 1.0)) {
            val peak = SpectrumTransform.bands(tone(frequency, amplitude), 48000).maxOrNull()!!
            assertEquals(amplitude, peak, 0.002)
        }
        assertEquals(1.0, SpectrumTransform.bands(tone(frequency, 2.0), 48000).maxOrNull()!!, 0.0)
    }

    @Test fun silenceAndFrequencySeparation() {
        assertTrue(SpectrumTransform.bands(DoubleArray(1024), 48000).all { it == 0.0 })
        val low = SpectrumTransform.bands(tone(250.0), 48000)
        val high = SpectrumTransform.bands(tone(8000.0), 48000)
        assertTrue(low.indices.maxBy { low[it] } < high.indices.maxBy { high[it] })
        assertTrue(low.all { it.isFinite() && it in 0.0..1.0 })
        val quiet = SpectrumTransform.bands(tone(250.0, 0.005), 48000)
        assertTrue(low.maxOrNull()!! > quiet.maxOrNull()!! + 0.3)
    }

    @Test fun pcmOutputIsUnchangedAndFlushClearsSpectrum() {
        val capture = SpectrumCapture()
        capture.enabled = true
        val processor = SpectrumAudioProcessor(capture)
        processor.configure(AudioProcessor.AudioFormat(48000, 2, C.ENCODING_PCM_16BIT))
        processor.flush()
        val original = ByteBuffer.allocateDirect(4096).order(ByteOrder.nativeOrder())
        for (sample in tone(1000.0)) {
            original.putShort((sample * 32767).toInt().toShort())
            original.putShort((sample * 32767).toInt().toShort())
        }
        original.flip()
        val expected = ByteArray(original.remaining())
        original.duplicate().get(expected)
        processor.queueInput(original)
        val output = processor.output
        val actual = ByteArray(output.remaining())
        output.get(actual)
        assertArrayEquals(expected, actual)
        assertTrue(capture.bands().any { it > 0.2 })
        processor.flush()
        assertTrue(capture.bands().all { it == 0.0 })
        capture.enabled = false
        assertTrue(capture.bands().all { it == 0.0 })
    }

    @Test fun captureIgnoresUnsupportedOutputAndStaleSamples() {
        val capture = SpectrumCapture()
        capture.enabled = true
        val buffer = ByteBuffer.allocateDirect(4096).order(ByteOrder.nativeOrder())
        tone(1000.0).forEach { buffer.putFloat(it.toFloat()) }
        buffer.flip()
        capture.capture(buffer, AudioProcessor.AudioFormat(48000, 1, C.ENCODING_PCM_FLOAT))
        assertTrue(capture.bands().any { it > 0.2 })
        Thread.sleep(280)
        assertTrue(capture.bands().all { it == 0.0 })
    }
}
