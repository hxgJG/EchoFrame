package com.hxg.lumio

import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import android.content.Context
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

class LumioPlaybackService : MediaSessionService() {
    private var mediaSession: MediaSession? = null
    private lateinit var player: ExoPlayer
    private lateinit var crossfadePlayer: ExoPlayer
    private val spectrumCapture = SpectrumCapture()
    private val crossfadeCapture = SpectrumCapture()
    private val spectrumWorker = Executors.newSingleThreadScheduledExecutor()
    private var spectrumTask: ScheduledFuture<*>? = null
    private data class SpectrumFrame(val primary: DoubleArray, val secondary: DoubleArray)
    private val spectrumGeneration = AtomicInteger()
    @Volatile private var spectrum = SpectrumFrame(DoubleArray(24), DoubleArray(24))
    private val handler = Handler(Looper.getMainLooper())
    private var crossfadeDurationMs = 0L
    private var crossfadeStartedAtMs = 0L
    private var crossfadeTargetIndex = C.INDEX_UNSET
    private var crossfadeBaseVolume = 1f
    private var crossfadeActive = false
    private var handoffInProgress = false
    private var crossfadeMonitorScheduled = false
    private val crossfadeMonitor = object : Runnable {
        override fun run() {
            crossfadeMonitorScheduled = false
            monitorCrossfade()
            scheduleCrossfadeMonitor()
        }
    }
    private val playerListener = object : Player.Listener {
        override fun onPlayerError(error: PlaybackException) {
            // MediaSession 传递异常时可能丢失 cause；在播放器所在服务保留原始栈。
            playbackFailureDetails = "${error.errorCodeName}: ${error.message}\n" +
                error.stackTraceToString().take(12000)
            Log.e("LumioPlayback", "${error.errorCodeName}: ${error.message}", error)
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            reconcileSpectrum()
            if (isPlaying) {
                scheduleCrossfadeMonitor()
            } else if (!handoffInProgress) {
                cancelCrossfade()
            }
        }

        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            clearSpectrum()
            if (!handoffInProgress) {
                cancelCrossfade()
            }
        }

        override fun onPositionDiscontinuity(
            oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int,
        ) {
            clearSpectrum()
        }
    }
    private val crossfadePlayerListener = object : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            if (isPlaying && crossfadeActive) {
                crossfadeStartedAtMs = android.os.SystemClock.elapsedRealtime()
            }
        }

        override fun onPlayerError(error: PlaybackException) {
            cancelCrossfade()
        }
    }

    override fun onCreate() {
        super.onCreate()
        player = buildPlayer(handleAudioFocus = true, capture = spectrumCapture)
        crossfadePlayer = buildPlayer(handleAudioFocus = false, capture = crossfadeCapture)
        player.addListener(playerListener)
        crossfadePlayer.addListener(crossfadePlayerListener)
        mediaSession = MediaSession.Builder(this, player).build()
        activeInstance = this
        reconcileSpectrum()
    }

    override fun onGetSession(
        controllerInfo: MediaSession.ControllerInfo,
    ): MediaSession? = mediaSession

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        activeInstance = null
        spectrumCapture.enabled = false
        crossfadeCapture.enabled = false
        spectrumTask?.cancel(false)
        spectrumWorker.shutdownNow()
        cancelCrossfade()
        player.removeListener(playerListener)
        crossfadePlayer.removeListener(crossfadePlayerListener)
        crossfadePlayer.release()
        mediaSession?.run {
            player.release()
            release()
        }
        mediaSession = null
        super.onDestroy()
    }

    private fun buildPlayer(handleAudioFocus: Boolean, capture: SpectrumCapture): ExoPlayer {
        val renderers = object : DefaultRenderersFactory(this) {
            override fun buildAudioSink(context: Context, enableFloatOutput: Boolean,
                enableAudioOutputPlaybackParams: Boolean): AudioSink =
                DefaultAudioSink.Builder(context)
                    .setEnableFloatOutput(enableFloatOutput)
                    .setEnableAudioOutputPlaybackParameters(enableAudioOutputPlaybackParams)
                    .setAudioProcessors(arrayOf(SpectrumAudioProcessor(capture)))
                    .build()
        }
        return ExoPlayer.Builder(this, renderers)
            .build()
            .apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(C.USAGE_MEDIA)
                        .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                        .build(),
                    handleAudioFocus,
                )
                setHandleAudioBecomingNoisy(handleAudioFocus)
            }
    }

    private fun setCrossfadeDuration(durationMs: Long) {
        crossfadeDurationMs = durationMs.coerceIn(0L, 10_000L)
        if (crossfadeDurationMs == 0L) {
            handler.removeCallbacks(crossfadeMonitor)
            crossfadeMonitorScheduled = false
            cancelCrossfade()
        } else {
            scheduleCrossfadeMonitor()
        }
    }

    private fun scheduleCrossfadeMonitor() {
        if (
            crossfadeDurationMs <= 0L ||
            !player.isPlaying ||
            crossfadeMonitorScheduled
        ) {
            return
        }
        crossfadeMonitorScheduled = true
        handler.postDelayed(crossfadeMonitor, 80L)
    }

    private fun monitorCrossfade() {
        if (crossfadeDurationMs <= 0L || handoffInProgress) {
            return
        }
        if (crossfadeActive) {
            if (crossfadePlayer.isPlaying) {
                updateCrossfadeVolumes()
            }
            return
        }
        if (!player.isPlaying || player.currentMediaItem?.mediaMetadata?.extras
                ?.getString("kind") != "audio"
        ) {
            return
        }
        val duration = player.duration
        if (
            duration == C.TIME_UNSET ||
            duration <= crossfadeDurationMs * 2 ||
            duration - player.currentPosition > crossfadeDurationMs
        ) {
            return
        }
        val nextIndex = player.nextMediaItemIndex
        if (
            nextIndex == C.INDEX_UNSET ||
            nextIndex == player.currentMediaItemIndex ||
            player.getMediaItemAt(nextIndex).mediaMetadata.extras
                ?.getString("kind") != "audio"
        ) {
            return
        }
        startCrossfade(nextIndex)
    }

    private fun startCrossfade(nextIndex: Int) {
        crossfadeTargetIndex = nextIndex
        crossfadeBaseVolume = player.volume
        crossfadeStartedAtMs = android.os.SystemClock.elapsedRealtime()
        crossfadeActive = true
        crossfadePlayer.setMediaItem(player.getMediaItemAt(nextIndex))
        crossfadePlayer.volume = 0f
        crossfadePlayer.prepare()
        crossfadePlayer.play()
    }

    private fun updateCrossfadeVolumes() {
        val elapsed =
            android.os.SystemClock.elapsedRealtime() - crossfadeStartedAtMs
        val progress =
            (elapsed.toFloat() / crossfadeDurationMs.toFloat()).coerceIn(0f, 1f)
        player.volume = crossfadeBaseVolume * (1f - progress)
        crossfadePlayer.volume = crossfadeBaseVolume * progress
        if (progress < 1f) {
            return
        }
        val targetIndex = crossfadeTargetIndex
        if (targetIndex == C.INDEX_UNSET) {
            cancelCrossfade()
            return
        }
        crossfadeActive = false
        handoffInProgress = true
        player.volume = 0f
        player.seekTo(targetIndex, crossfadePlayer.currentPosition.coerceAtLeast(0L))
        player.play()
        finishHandoffWhenReady(attemptsRemaining = 30)
    }

    private fun finishHandoffWhenReady(attemptsRemaining: Int) {
        if (
            player.playbackState != Player.STATE_READY &&
            attemptsRemaining > 0
        ) {
            handler.postDelayed(
                { finishHandoffWhenReady(attemptsRemaining - 1) },
                50L,
            )
            return
        }
        player.volume = crossfadeBaseVolume
        crossfadePlayer.stop()
        crossfadePlayer.clearMediaItems()
        crossfadePlayer.volume = 0f
        crossfadeTargetIndex = C.INDEX_UNSET
        handoffInProgress = false
    }

    private fun cancelCrossfade() {
        val shouldRestoreVolume = crossfadeActive || handoffInProgress
        if (::player.isInitialized && shouldRestoreVolume) {
            player.volume = crossfadeBaseVolume
        }
        if (::crossfadePlayer.isInitialized) {
            crossfadePlayer.stop()
            crossfadePlayer.clearMediaItems()
            crossfadePlayer.volume = 0f
        }
        crossfadeActive = false
        handoffInProgress = false
        crossfadeTargetIndex = C.INDEX_UNSET
    }

    companion object {
        @Volatile var playbackFailureDetails: String? = null
            private set

        fun clearPlaybackFailure() { playbackFailureDetails = null }

        @Volatile private var spectrumRequested = false
        @Volatile
        private var activeInstance: LumioPlaybackService? = null

        fun configureSpectrum(enabled: Boolean) {
            spectrumRequested = enabled
            activeInstance?.reconcileSpectrum()
        }

        fun readSpectrum(): List<Double> = activeInstance?.readBands() ?: emptyList()

        fun updateCrossfadeDuration(durationMs: Long) {
            activeInstance?.setCrossfadeDuration(durationMs)
        }
    }

    private fun reconcileSpectrum() {
        val enabled = spectrumRequested && ::player.isInitialized && player.isPlaying
        spectrumCapture.enabled = enabled
        crossfadeCapture.enabled = enabled
        if (!enabled) {
            spectrumTask?.cancel(false)
            spectrumTask = null
            clearSpectrum()
            return
        }
        if (spectrumTask != null) return
        spectrumTask = spectrumWorker.scheduleAtFixedRate({
            val generation = spectrumGeneration.get()
            val primary = spectrumCapture.bands()
            val secondary = crossfadeCapture.bands()
            // Publication is atomic; no platform calls or allocations on the audio thread.
            if (spectrumCapture.enabled && generation == spectrumGeneration.get()) {
                spectrum = SpectrumFrame(primary, secondary)
            }
        }, 0, 50, TimeUnit.MILLISECONDS)
    }

    private fun clearSpectrum() {
        spectrumGeneration.incrementAndGet()
        spectrumCapture.clear()
        crossfadeCapture.clear()
        spectrum = SpectrumFrame(DoubleArray(24), DoubleArray(24))
    }

    private fun readBands(): List<Double> {
        if (!spectrumRequested || !player.isPlaying) return emptyList()
        val frame = spectrum
        val primaryVolume = player.volume.toDouble()
        val secondaryVolume = if (crossfadeActive || handoffInProgress) crossfadePlayer.volume.toDouble() else 0.0
        fun scaled(value: Double, volume: Double): Double =
            (value * volume).coerceIn(0.0, 1.0)
        return List(24) { maxOf(scaled(frame.primary[it], primaryVolume), scaled(frame.secondary[it], secondaryVolume)) }
    }
}
