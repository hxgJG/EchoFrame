package com.hxg.lumio

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.locks.ReentrantLock
import kotlin.math.*

/** Bounded PCM capture; the audio thread never waits for the analysis worker. */
internal class SpectrumCapture {
    @Volatile var enabled = false
    private val lock = ReentrantLock()
    private val ring = FloatArray(4096)
    private var count = 0L
    private var rate = 44100
    private var lastAt = 0L

    fun capture(buffer: ByteBuffer, format: AudioProcessor.AudioFormat) {
        if (!enabled || !lock.tryLock()) return
        try {
            val bytes = if (format.encoding == C.ENCODING_PCM_FLOAT) 4 else 2
            val stride = bytes * format.channelCount
            if (stride <= 0) return
            val end = buffer.limit()
            var offset = max(buffer.position(), end - 4096 * stride)
            offset -= (offset - buffer.position()) % stride
            buffer.order(ByteOrder.nativeOrder())
            while (offset + stride <= end) {
                val sample = if (bytes == 4) buffer.getFloat(offset) else buffer.getShort(offset) / 32768f
                ring[(count++ % ring.size).toInt()] = if (sample.isFinite()) sample else 0f
                offset += stride
            }
            rate = format.sampleRate
            lastAt = System.nanoTime()
        } finally { lock.unlock() }
    }

    fun clear() {
        lock.lock()
        try { count = 0; lastAt = 0 } finally { lock.unlock() }
    }

    fun bands(): DoubleArray {
        val input = DoubleArray(1024)
        val sampleRate: Int
        lock.lock()
        try {
            if (!enabled || count < 1024 || System.nanoTime() - lastAt > 250_000_000) return DoubleArray(24)
            for (i in input.indices) input[i] = ring[((count - 1024 + i) % ring.size).toInt()].toDouble()
            sampleRate = rate
        } finally { lock.unlock() }
        return SpectrumTransform.bands(input, sampleRate)
    }
}

internal class SpectrumAudioProcessor(private val capture: SpectrumCapture) : BaseAudioProcessor() {
    override fun onConfigure(format: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat =
        if (format.encoding == C.ENCODING_PCM_16BIT || format.encoding == C.ENCODING_PCM_FLOAT) format
        else AudioProcessor.AudioFormat.NOT_SET

    override fun queueInput(inputBuffer: ByteBuffer) {
        capture.capture(inputBuffer, inputAudioFormat)
        val output = replaceOutputBuffer(inputBuffer.remaining())
        output.put(inputBuffer).flip()
    }

    override fun onFlush() { capture.clear() }
    override fun onReset() { capture.clear() }
}

internal object SpectrumTransform {
    private val window = DoubleArray(1024) { 0.5 - 0.5 * cos(2 * PI * it / 1023) }

    fun bands(samples: DoubleArray, sampleRate: Int): DoubleArray {
        require(samples.size == 1024 && sampleRate > 0)
        val real = DoubleArray(1024) { samples[it] * window[it] }
        val imaginary = DoubleArray(1024)
        var j = 0
        for (i in 1 until 1024) {
            var bit = 512
            while (j and bit != 0) { j = j xor bit; bit = bit shr 1 }
            j = j xor bit
            if (i < j) { val v = real[i]; real[i] = real[j]; real[j] = v }
        }
        var length = 2
        while (length <= 1024) {
            val angle = -2 * PI / length
            val wr = cos(angle); val wi = sin(angle)
            for (start in 0 until 1024 step length) {
                var ar = 1.0; var ai = 0.0
                for (k in 0 until length / 2) {
                    val a = start + k; val b = a + length / 2
                    val br = real[b] * ar - imaginary[b] * ai
                    val bi = real[b] * ai + imaginary[b] * ar
                    real[b] = real[a] - br; imaginary[b] = imaginary[a] - bi
                    real[a] += br; imaginary[a] += bi
                    val next = ar * wr - ai * wi
                    ai = ar * wi + ai * wr; ar = next
                }
            }
            length *= 2
        }
        val high = min(16000.0, sampleRate * 0.48)
        return DoubleArray(24) { band ->
            val lowBin = max(1, (60 * (high / 60).pow(band / 24.0) * 1024 / sampleRate).toInt())
            val highBin = min(511, max(lowBin, (60 * (high / 60).pow((band + 1) / 24.0) * 1024 / sampleRate).toInt()))
            var power = 0.0
            for (bin in lowBin..highBin) power = max(power, real[bin] * real[bin] + imaginary[bin] * imaginary[bin])
            val magnitude = sqrt(power) * 4 / 1024
            // Fixed full-scale PCM reference; do not amplify quiet tracks or normalize per song.
            magnitude.coerceIn(0.0, 1.0)
        }
    }
}
