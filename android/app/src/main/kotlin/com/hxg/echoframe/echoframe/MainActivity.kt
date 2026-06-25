package com.hxg.echoframe.echoframe

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.content.ContentResolver
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.database.Cursor
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.audiofx.Equalizer
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.view.Surface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private val notificationChannelId = "echoframe_playback"
    private val playbackNotificationId = 2408
    private val actionPlayPause = "com.hxg.echoframe.PLAY_PAUSE"
    private val actionNext = "com.hxg.echoframe.NEXT"
    private val actionPrevious = "com.hxg.echoframe.PREVIOUS"
    private val mediaLibraryChannelName = "echoframe/media_library"
    private val appStorageChannelName = "echoframe/app_storage"
    private val playbackChannelName = "echoframe/playback"
    private val permissionRequestCode = 2407
    private var pendingScanResult: MethodChannel.Result? = null
    private var pendingScanArguments: Any? = null
    private var playbackChannel: MethodChannel? = null
    private var flutterTextureRegistry: TextureRegistry? = null
    private var mediaPlayer: MediaPlayer? = null
    private var videoTextureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var videoSurface: Surface? = null
    private var currentPlaybackMediaId: String? = null
    private var currentPlaybackTitle: String = "EchoFrame"
    private var currentPlaybackArtist: String = "Local media"
    private var currentPlaybackAlbum: String = ""
    private var playbackSpeed: Float = 1.0f
    private var volumeScale: Float = 1.0f
    private var equalizerPreset: String = "off"
    private var customEqualizerGains: List<Int> = listOf(0, 0, 0, 0, 0)
    private var equalizer: Equalizer? = null
    private var audioManager: AudioManager? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var mediaSession: MediaSession? = null
    private var noisyReceiverRegistered = false
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                pauseForSystem("pause")
            }
        }
    }
    private val audioFocusChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        when (focusChange) {
            AudioManager.AUDIOFOCUS_LOSS,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
            -> pauseForSystem("pause")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterTextureRegistry = flutterEngine.renderer
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        createNotificationChannel()
        setupMediaSession()
        registerNoisyReceiver()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mediaLibraryChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scan" -> scanMediaLibrary(call.arguments, result)
                    "restoreLastScan" -> restoreLastScan(result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, appStorageChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "load" -> loadAppState(result)
                    "save" -> saveAppState(call.arguments, result)
                    "createBackup" -> createAppBackup(call.arguments, result)
                    "restoreLatestBackup" -> restoreLatestBackup(result)
                    "latestBackup" -> latestBackup(result)
                    else -> result.notImplemented()
                }
            }
        playbackChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, playbackChannelName)
        playbackChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "play" -> playMedia(call.arguments, result)
                "pause" -> pauseMedia(result)
                "resume" -> resumeMedia(result)
                "seek" -> seekMedia(call.arguments, result)
                "setSpeed" -> setPlaybackSpeed(call.arguments, result)
                "setEqualizerPreset" -> setEqualizerPreset(call.arguments, result)
                "setVolumeScale" -> setVolumeScale(call.arguments, result)
                "stop" -> stopMedia(result)
                "position" -> playbackPosition(result)
                "enterPictureInPicture" -> enterPip(result)
                "adjustBrightness" -> adjustBrightness(call.arguments, result)
                "adjustVolume" -> adjustVolume(call.arguments, result)
                "share" -> shareMedia(call.arguments, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun shareMedia(arguments: Any?, result: MethodChannel.Result) {
        try {
            val values = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
            val mediaId = values["mediaId"]?.toString().orEmpty()
            val kind = values["kind"]?.toString().orEmpty()
            val title = values["title"]?.toString().orEmpty().ifBlank { "EchoFrame media" }
            val uri = mediaStoreUri(mediaId, kind)
            if (uri == null) {
                result.error("shareUnsupported", "只能分享 Android 媒体库扫描到的本地媒体。", null)
                return
            }
            val mimeType = contentResolver.getType(uri) ?: if (kind == "video") "video/*" else "audio/*"
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_TITLE, title)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, "分享媒体"))
            result.success(null)
        } catch (error: Exception) {
            result.error("shareFailed", error.message ?: "Share media failed.", null)
        }
    }

    private fun mediaStoreUri(mediaId: String, kind: String): Uri? {
        val numericId = mediaId.substringAfterLast('-', missingDelimiterValue = "")
            .toLongOrNull() ?: return null
        val baseUri = when (kind) {
            "audio" -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
            "video" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            else -> return null
        }
        return Uri.withAppendedPath(baseUri, numericId.toString())
    }

    private fun createAppBackup(arguments: Any?, result: MethodChannel.Result) {
        try {
            val value = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
            val text = JSONObject(value).toString()
            appStateFile().writeText(text)
            val file = File(backupDirectory(), "echoframe-backup-${System.currentTimeMillis()}.json")
            file.writeText(text)
            result.success(backupInfo(file))
        } catch (error: Exception) {
            result.error("backupFailed", error.message ?: "Create backup failed.", null)
        }
    }

    private fun restoreLatestBackup(result: MethodChannel.Result) {
        try {
            val file = latestBackupFile()
            if (file == null) {
                result.success(null)
                return
            }
            val text = file.readText()
            appStateFile().writeText(text)
            result.success(JSONObject(text).toMap())
        } catch (error: Exception) {
            result.error("restoreFailed", error.message ?: "Restore backup failed.", null)
        }
    }

    private fun latestBackup(result: MethodChannel.Result) {
        result.success(latestBackupFile()?.let { backupInfo(it) })
    }

    override fun onDestroy() {
        releaseMediaPlayer()
        cancelPlaybackNotification()
        abandonAudioFocus()
        unregisterNoisyReceiver()
        mediaSession?.release()
        mediaSession = null
        flutterTextureRegistry = null
        playbackChannel = null
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handlePlaybackIntent(intent)
    }

    private fun scanMediaLibrary(arguments: Any?, result: MethodChannel.Result) {
        if (!hasMediaPermissions()) {
            pendingScanResult = result
            pendingScanArguments = arguments
            requestPermissions(requiredMediaPermissions(), permissionRequestCode)
            return
        }

        try {
            val filter = ScanFilter.from(arguments)
            val audioItems = queryAudio(filter)
            val videoItems = queryVideo(filter)
            saveScanSnapshot(audioItems, videoItems)
            result.success(
                mapOf(
                    "status" to "completed",
                    "audioItems" to audioItems,
                    "videoItems" to videoItems,
                ),
            )
        } catch (error: Exception) {
            result.success(
                mapOf(
                    "status" to "failed",
                    "message" to (error.message ?: "MediaStore scan failed."),
                    "audioItems" to emptyList<Map<String, Any?>>(),
                    "videoItems" to emptyList<Map<String, Any?>>(),
                ),
            )
        }
    }

    private fun restoreLastScan(result: MethodChannel.Result) {
        val file = snapshotFile()
        if (!file.exists()) {
            result.success(
                mapOf(
                    "status" to "empty",
                    "message" to "No media library snapshot.",
                    "audioItems" to emptyList<Map<String, Any?>>(),
                    "videoItems" to emptyList<Map<String, Any?>>(),
                ),
            )
            return
        }

        try {
            val root = JSONObject(file.readText())
            result.success(
                mapOf(
                    "status" to "completed",
                    "message" to "Restored media library snapshot.",
                    "audioItems" to root.optJSONArray("audioItems").toMapList(),
                    "videoItems" to root.optJSONArray("videoItems").toMapList(),
                ),
            )
        } catch (error: Exception) {
            result.success(
                mapOf(
                    "status" to "failed",
                    "message" to (error.message ?: "Restore media library snapshot failed."),
                    "audioItems" to emptyList<Map<String, Any?>>(),
                    "videoItems" to emptyList<Map<String, Any?>>(),
                ),
            )
        }
    }

    private fun loadAppState(result: MethodChannel.Result) {
        val file = appStateFile()
        if (!file.exists()) {
            result.success(null)
            return
        }

        try {
            result.success(JSONObject(file.readText()).toMap())
        } catch (error: Exception) {
            result.success(null)
        }
    }

    private fun saveAppState(arguments: Any?, result: MethodChannel.Result) {
        try {
            val value = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
            appStateFile().writeText(JSONObject(value).toString())
            result.success(null)
        } catch (error: Exception) {
            result.error("saveFailed", error.message ?: "Save app state failed.", null)
        }
    }

    private fun playMedia(arguments: Any?, result: MethodChannel.Result) {
        val values = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        val path = values["path"]?.toString().orEmpty()
        val mediaId = values["mediaId"]?.toString().orEmpty()
        val kind = values["kind"]?.toString().orEmpty()
        currentPlaybackTitle = values["title"]?.toString().orEmpty().ifBlank { "EchoFrame" }
        currentPlaybackArtist = values["artist"]?.toString().orEmpty().ifBlank { "Local media" }
        currentPlaybackAlbum = values["album"]?.toString().orEmpty()
        val startPositionMs = (values["positionMs"] as? Number)?.toInt()
            ?: values["positionMs"]?.toString()?.toIntOrNull()
            ?: 0
        if (path.isBlank()) {
            result.error("invalidPath", "Media path is empty.", null)
            return
        }

        try {
            releaseMediaPlayer()
            if (!requestAudioFocus()) {
                result.error("audioFocusDenied", "Audio focus request was denied.", null)
                return
            }
            currentPlaybackMediaId = mediaId
            val textureId = if (kind == "video") prepareVideoSurface() else null
            mediaPlayer = MediaPlayer().apply {
                setDataSource(path)
                videoSurface?.let { setSurface(it) }
                setOnCompletionListener {
                    playbackChannel?.invokeMethod(
                        "completed",
                        mapOf("mediaId" to currentPlaybackMediaId),
                    )
                }
                setOnErrorListener { _, what, extra ->
                    playbackChannel?.invokeMethod(
                        "error",
                        mapOf(
                            "mediaId" to currentPlaybackMediaId,
                            "message" to "MediaPlayer error: $what/$extra",
                        ),
                    )
                    true
                }
                prepare()
                if (startPositionMs > 0) {
                    seekTo(startPositionMs.coerceAtMost(duration))
                }
                applyPlaybackSpeed(this)
                applyEqualizer(this)
                applyVolumeScale(this)
                start()
            }
            updatePlaybackState(true)
            showPlaybackNotification(true)
            result.success(mapOf("textureId" to textureId))
        } catch (error: Exception) {
            releaseMediaPlayer()
            abandonAudioFocus()
            result.error("playFailed", error.message ?: "Play media failed.", null)
        }
    }

    private fun setPlaybackSpeed(arguments: Any?, result: MethodChannel.Result) {
        val values = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        val speed = (values["speed"] as? Number)?.toFloat()
            ?: values["speed"]?.toString()?.toFloatOrNull()
            ?: 1.0f
        playbackSpeed = speed.coerceIn(0.5f, 2.0f)
        try {
            mediaPlayer?.let { applyPlaybackSpeed(it) }
            result.success(null)
        } catch (error: Exception) {
            result.error("speedFailed", error.message ?: "Set playback speed failed.", null)
        }
    }

    private fun setEqualizerPreset(arguments: Any?, result: MethodChannel.Result) {
        val values = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        equalizerPreset = values["preset"]?.toString().orEmpty().ifBlank { "off" }
        customEqualizerGains = intListArgument(values["customGains"])
        try {
            mediaPlayer?.let { applyEqualizer(it) }
            result.success(null)
        } catch (error: Exception) {
            result.error("equalizerFailed", error.message ?: "Set equalizer failed.", null)
        }
    }

    private fun setVolumeScale(arguments: Any?, result: MethodChannel.Result) {
        volumeScale = doubleArgument(arguments, "scale").toFloat().coerceIn(0f, 1f)
        try {
            mediaPlayer?.let { applyVolumeScale(it) }
            result.success(null)
        } catch (error: Exception) {
            result.error("volumeScaleFailed", error.message ?: "Set playback volume failed.", null)
        }
    }

    private fun pauseMedia(result: MethodChannel.Result) {
        try {
            mediaPlayer?.takeIf { it.isPlaying }?.pause()
            updatePlaybackState(false)
            showPlaybackNotification(false)
            result.success(null)
        } catch (error: Exception) {
            result.error("pauseFailed", error.message ?: "Pause media failed.", null)
        }
    }

    private fun resumeMedia(result: MethodChannel.Result) {
        try {
            if (!requestAudioFocus()) {
                result.error("audioFocusDenied", "Audio focus request was denied.", null)
                return
            }
            mediaPlayer?.start()
            updatePlaybackState(true)
            showPlaybackNotification(true)
            result.success(null)
        } catch (error: Exception) {
            result.error("resumeFailed", error.message ?: "Resume media failed.", null)
        }
    }

    private fun seekMedia(arguments: Any?, result: MethodChannel.Result) {
        val values = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        val positionMs = (values["positionMs"] as? Number)?.toInt()
            ?: values["positionMs"]?.toString()?.toIntOrNull()
            ?: 0
        try {
            mediaPlayer?.let { player ->
                player.seekTo(positionMs.coerceIn(0, player.duration.coerceAtLeast(0)))
            }
            result.success(null)
        } catch (error: Exception) {
            result.error("seekFailed", error.message ?: "Seek media failed.", null)
        }
    }

    private fun stopMedia(result: MethodChannel.Result) {
        volumeScale = 1.0f
        releaseMediaPlayer()
        abandonAudioFocus()
        cancelPlaybackNotification()
        result.success(null)
    }

    private fun playbackPosition(result: MethodChannel.Result) {
        try {
            result.success(mediaPlayer?.currentPosition ?: 0)
        } catch (error: Exception) {
            result.success(0)
        }
    }

    private fun enterPip(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(false)
            return
        }
        try {
            enterPictureInPictureMode(PictureInPictureParams.Builder().build())
            result.success(true)
        } catch (error: Exception) {
            result.error("pipFailed", error.message ?: "Enter PiP failed.", null)
        }
    }

    private fun adjustBrightness(arguments: Any?, result: MethodChannel.Result) {
        val delta = doubleArgument(arguments, "delta").toFloat()
        try {
            val attributes = window.attributes
            val current = if (attributes.screenBrightness >= 0f) attributes.screenBrightness else 0.5f
            attributes.screenBrightness = (current + delta).coerceIn(0.05f, 1.0f)
            window.attributes = attributes
            result.success(attributes.screenBrightness.toDouble())
        } catch (error: Exception) {
            result.error("brightnessFailed", error.message ?: "Adjust brightness failed.", null)
        }
    }

    private fun adjustVolume(arguments: Any?, result: MethodChannel.Result) {
        val delta = doubleArgument(arguments, "delta")
        val manager = audioManager
        if (manager == null) {
            result.success(null)
            return
        }
        try {
            val maxVolume = manager.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
            val current = manager.getStreamVolume(AudioManager.STREAM_MUSIC)
            val next = (current + (delta * maxVolume).toInt()).coerceIn(0, maxVolume)
            manager.setStreamVolume(AudioManager.STREAM_MUSIC, next, 0)
            result.success(next.toDouble() / maxVolume.toDouble())
        } catch (error: Exception) {
            result.error("volumeFailed", error.message ?: "Adjust volume failed.", null)
        }
    }

    private fun doubleArgument(arguments: Any?, key: String): Double {
        val values = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        return (values[key] as? Number)?.toDouble()
            ?: values[key]?.toString()?.toDoubleOrNull()
            ?: 0.0
    }

    private fun intListArgument(value: Any?): List<Int> {
        val raw = value as? List<*> ?: return listOf(0, 0, 0, 0, 0)
        val gains = raw
            .map {
                val decibels = (it as? Number)?.toDouble()
                    ?: it?.toString()?.toDoubleOrNull()
                    ?: 0.0
                (decibels.coerceIn(-10.0, 10.0) * 100).toInt()
            }
            .take(5)
        if (gains.size >= 5) {
            return gains
        }
        return gains + List(5 - gains.size) { 0 }
    }

    private fun requestAudioFocus(): Boolean {
        val manager = audioManager ?: return true
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = audioFocusRequest ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setOnAudioFocusChangeListener(audioFocusChangeListener)
                .build()
                .also { audioFocusRequest = it }
            manager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            manager.requestAudioFocus(
                audioFocusChangeListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN,
            ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    }

    private fun abandonAudioFocus() {
        val manager = audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { manager.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            manager.abandonAudioFocus(audioFocusChangeListener)
        }
    }

    private fun pauseForSystem(method: String) {
        try {
            mediaPlayer?.takeIf { it.isPlaying }?.pause()
            updatePlaybackState(false)
            showPlaybackNotification(false)
            playbackChannel?.invokeMethod(method, null)
        } catch (_: Exception) {
            playbackChannel?.invokeMethod(method, null)
        }
    }

    private fun setupMediaSession() {
        mediaSession = MediaSession(this, "EchoFrame").apply {
            setCallback(
                object : MediaSession.Callback() {
                    override fun onPlay() {
                        playbackChannel?.invokeMethod("play", null)
                    }

                    override fun onPause() {
                        pauseForSystem("pause")
                    }

                    override fun onSkipToNext() {
                        playbackChannel?.invokeMethod("next", null)
                    }

                    override fun onSkipToPrevious() {
                        playbackChannel?.invokeMethod("previous", null)
                    }

                    override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                        playbackChannel?.invokeMethod("toggle", null)
                        return true
                    }
                },
            )
            isActive = true
        }
        updatePlaybackState(false)
    }

    private fun updatePlaybackState(isPlaying: Boolean) {
        val actions = PlaybackState.ACTION_PLAY or
            PlaybackState.ACTION_PAUSE or
            PlaybackState.ACTION_PLAY_PAUSE or
            PlaybackState.ACTION_SKIP_TO_NEXT or
            PlaybackState.ACTION_SKIP_TO_PREVIOUS
        mediaSession?.setPlaybackState(
            PlaybackState.Builder()
                .setActions(actions)
                .setState(
                    if (isPlaying) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    mediaPlayer?.currentPosition?.toLong() ?: 0L,
                    playbackSpeed,
                )
                .build(),
        )
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            notificationChannelId,
            "EchoFrame playback",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Local media playback controls"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun showPlaybackNotification(isPlaying: Boolean) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(playbackNotificationId, buildPlaybackNotification(isPlaying))
    }

    private fun cancelPlaybackNotification() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(playbackNotificationId)
    }

    private fun buildPlaybackNotification(isPlaying: Boolean): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            pendingIntentFlags(),
        )
        val playPauseTitle = if (isPlaying) "Pause" else "Play"
        val playPauseIcon = if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, notificationChannelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(currentPlaybackTitle)
            .setContentText(
                listOf(currentPlaybackArtist, currentPlaybackAlbum)
                    .filter { it.isNotBlank() }
                    .joinToString(" • ")
                    .ifBlank { "EchoFrame" },
            )
            .setContentIntent(contentIntent)
            .setOngoing(isPlaying)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(mediaSession?.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2),
            )
            .addAction(
                android.R.drawable.ic_media_previous,
                "Previous",
                playbackActionIntent(actionPrevious, 1),
            )
            .addAction(
                playPauseIcon,
                playPauseTitle,
                playbackActionIntent(actionPlayPause, 2),
            )
            .addAction(
                android.R.drawable.ic_media_next,
                "Next",
                playbackActionIntent(actionNext, 3),
            )
            .build()
    }

    private fun playbackActionIntent(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).setAction(action)
        return PendingIntent.getActivity(this, requestCode, intent, pendingIntentFlags())
    }

    private fun pendingIntentFlags(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
    }

    private fun handlePlaybackIntent(intent: Intent?) {
        when (intent?.action) {
            actionPlayPause -> {
                val isPlaying = mediaPlayer?.isPlaying == true
                if (isPlaying) {
                    mediaPlayer?.pause()
                    updatePlaybackState(false)
                    showPlaybackNotification(false)
                    playbackChannel?.invokeMethod("pause", null)
                } else {
                    playbackChannel?.invokeMethod("play", null)
                }
            }
            actionNext -> playbackChannel?.invokeMethod("next", null)
            actionPrevious -> playbackChannel?.invokeMethod("previous", null)
        }
    }

    private fun registerNoisyReceiver() {
        if (noisyReceiverRegistered) {
            return
        }
        registerReceiver(noisyReceiver, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        noisyReceiverRegistered = true
    }

    private fun unregisterNoisyReceiver() {
        if (!noisyReceiverRegistered) {
            return
        }
        unregisterReceiver(noisyReceiver)
        noisyReceiverRegistered = false
    }

    private fun prepareVideoSurface(): Long? {
        val textureRegistry = flutterTextureRegistry ?: return null
        videoTextureEntry = textureRegistry.createSurfaceTexture()
        val texture = videoTextureEntry?.surfaceTexture() ?: return null
        videoSurface = Surface(texture)
        val textureId = videoTextureEntry?.id()
        playbackChannel?.invokeMethod(
            "videoTextureChanged",
            mapOf("textureId" to textureId),
        )
        return textureId
    }

    private fun applyPlaybackSpeed(player: MediaPlayer) {
        player.playbackParams = player.playbackParams.setSpeed(playbackSpeed)
    }

    private fun applyVolumeScale(player: MediaPlayer) {
        player.setVolume(volumeScale, volumeScale)
    }

    private fun applyEqualizer(player: MediaPlayer) {
        equalizer?.release()
        equalizer = null
        if (equalizerPreset == "off") {
            return
        }
        equalizer = Equalizer(0, player.audioSessionId).apply {
            enabled = true
            val bandCount = numberOfBands.toInt()
            val range = bandLevelRange
            val minLevel = range[0].toInt()
            val maxLevel = range[1].toInt()
            val gains = equalizerGains(equalizerPreset, bandCount)
            for (band in 0 until bandCount) {
                setBandLevel(
                    band.toShort(),
                    gains[band].coerceIn(minLevel, maxLevel).toShort(),
                )
            }
        }
    }

    private fun equalizerGains(preset: String, bandCount: Int): List<Int> {
        val points = when (preset) {
            "bassBoost" -> listOf(700, 450, 120, 0, -120)
            "vocal" -> listOf(-180, 0, 420, 360, 80)
            "rock" -> listOf(520, 220, -120, 260, 520)
            "classical" -> listOf(260, 160, 0, 240, 360)
            "custom" -> customEqualizerGains
            else -> listOf(0, 0, 0, 0, 0)
        }
        if (bandCount <= 0) {
            return emptyList()
        }
        if (bandCount == 1) {
            return listOf(points[points.size / 2])
        }
        return List(bandCount) { index ->
            val sourceIndex = (index * (points.size - 1)) / (bandCount - 1)
            points[sourceIndex]
        }
    }

    private fun releaseMediaPlayer() {
        equalizer?.release()
        equalizer = null
        mediaPlayer?.setOnCompletionListener(null)
        mediaPlayer?.setOnErrorListener(null)
        mediaPlayer?.setSurface(null)
        mediaPlayer?.release()
        mediaPlayer = null
        videoSurface?.release()
        videoSurface = null
        videoTextureEntry?.release()
        videoTextureEntry = null
        playbackChannel?.invokeMethod(
            "videoTextureChanged",
            mapOf("textureId" to null),
        )
        currentPlaybackMediaId = null
        updatePlaybackState(false)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != permissionRequestCode) {
            return
        }

        val result = pendingScanResult ?: return
        val arguments = pendingScanArguments
        pendingScanResult = null
        pendingScanArguments = null
        if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) {
            scanMediaLibrary(arguments, result)
        } else {
            result.success(
                mapOf(
                    "status" to "permissionDenied",
                    "message" to "需要授权读取本机音频/视频后才能扫描媒体库。",
                    "audioItems" to emptyList<Map<String, Any?>>(),
                    "videoItems" to emptyList<Map<String, Any?>>(),
                ),
            )
        }
    }

    private fun hasMediaPermissions(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true
        }
        return requiredMediaPermissions().all { permission ->
            checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requiredMediaPermissions(): Array<String> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            arrayOf(
                Manifest.permission.READ_MEDIA_AUDIO,
                Manifest.permission.READ_MEDIA_VIDEO,
            )
        } else {
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
    }

    private fun queryAudio(filter: ScanFilter): List<Map<String, Any?>> {
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.DATE_ADDED,
            MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.SIZE,
            MediaStore.Audio.Media.MIME_TYPE,
        )
        val selection =
            "${MediaStore.Audio.Media.IS_MUSIC}=1 AND ${MediaStore.Audio.Media.DURATION}>=${filter.minimumAudioDurationMs}"
        return queryMedia(
            uri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            projection = projection,
            selection = selection,
            sortOrder = "${MediaStore.Audio.Media.DATE_ADDED} DESC",
            kind = "audio",
            filter = filter,
        )
    }

    private fun queryVideo(filter: ScanFilter): List<Map<String, Any?>> {
        val projection = arrayOf(
            MediaStore.Video.Media._ID,
            MediaStore.Video.Media.TITLE,
            MediaStore.Video.Media.DURATION,
            MediaStore.Video.Media.DATE_ADDED,
            MediaStore.Video.Media.DATA,
            MediaStore.Video.Media.SIZE,
            MediaStore.Video.Media.MIME_TYPE,
            MediaStore.Video.Media.WIDTH,
            MediaStore.Video.Media.HEIGHT,
        )
        return queryMedia(
            uri = MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            projection = projection,
            selection = null,
            sortOrder = "${MediaStore.Video.Media.DATE_ADDED} DESC",
            kind = "video",
            filter = filter,
        )
    }

    private fun queryMedia(
        uri: Uri,
        projection: Array<String>,
        selection: String?,
        sortOrder: String,
        kind: String,
        filter: ScanFilter,
    ): List<Map<String, Any?>> {
        val resolver: ContentResolver = contentResolver
        val items = mutableListOf<Map<String, Any?>>()
        resolver.query(uri, projection, selection, null, sortOrder)?.use { cursor ->
            while (cursor.moveToNext()) {
                val row = if (kind == "video") videoRow(cursor) else audioRow(cursor)
                val path = row["path"]?.toString().orEmpty()
                if (filter.isIncluded(path) && !filter.isExcluded(path)) {
                    items.add(row)
                }
            }
        }
        return items
    }

    private fun audioRow(cursor: Cursor): Map<String, Any?> {
        val id = cursor.long(MediaStore.Audio.Media._ID)
        val path = cursor.string(MediaStore.Audio.Media.DATA)
        val mimeType = cursor.string(MediaStore.Audio.Media.MIME_TYPE)
        val row = mutableMapOf<String, Any?>(
            "id" to "android-audio-$id",
            "kind" to "audio",
            "title" to cursor.string(MediaStore.Audio.Media.TITLE).ifBlank { File(path).nameWithoutExtension },
            "artist" to cursor.string(MediaStore.Audio.Media.ARTIST).ifBlank { "Unknown artist" },
            "album" to cursor.string(MediaStore.Audio.Media.ALBUM).ifBlank { "Unknown album" },
            "durationMs" to cursor.long(MediaStore.Audio.Media.DURATION),
            "addedAtMs" to cursor.long(MediaStore.Audio.Media.DATE_ADDED) * 1000,
            "path" to path,
            "folder" to File(path).parent.orEmpty(),
            "sizeBytes" to cursor.long(MediaStore.Audio.Media.SIZE),
            "format" to formatLabel(mimeType, path),
        )
        readSameNameText(path, "lrc")?.let { row["lyricsText"] = it }
        return row
    }

    private fun videoRow(cursor: Cursor): Map<String, Any?> {
        val id = cursor.long(MediaStore.Video.Media._ID)
        val path = cursor.string(MediaStore.Video.Media.DATA)
        val mimeType = cursor.string(MediaStore.Video.Media.MIME_TYPE)
        val width = cursor.long(MediaStore.Video.Media.WIDTH)
        val height = cursor.long(MediaStore.Video.Media.HEIGHT)
        val row = mutableMapOf<String, Any?>(
            "id" to "android-video-$id",
            "kind" to "video",
            "title" to cursor.string(MediaStore.Video.Media.TITLE).ifBlank { File(path).nameWithoutExtension },
            "artist" to "Camera Roll",
            "album" to File(path).parentFile?.name.orEmpty().ifBlank { "Videos" },
            "durationMs" to cursor.long(MediaStore.Video.Media.DURATION),
            "addedAtMs" to cursor.long(MediaStore.Video.Media.DATE_ADDED) * 1000,
            "path" to path,
            "folder" to File(path).parent.orEmpty(),
            "sizeBytes" to cursor.long(MediaStore.Video.Media.SIZE),
            "format" to formatLabel(mimeType, path),
            "resolution" to resolutionLabel(width, height),
        )
        readSameNameText(path, "srt")?.let {
            row["subtitleText"] = it
        } ?: readSameNameText(path, "ass")?.let {
            row["assSubtitleText"] = it
        } ?: readSameNameText(path, "ssa")?.let {
            row["assSubtitleText"] = it
        }
        return row
    }

    private fun Cursor.long(column: String): Long {
        val index = getColumnIndex(column)
        return if (index >= 0 && !isNull(index)) getLong(index) else 0L
    }

    private fun Cursor.string(column: String): String {
        val index = getColumnIndex(column)
        return if (index >= 0 && !isNull(index)) getString(index).orEmpty() else ""
    }

    private fun formatLabel(mimeType: String, path: String): String {
        val extension = path.substringAfterLast('.', missingDelimiterValue = "")
        return extension.ifBlank { mimeType.substringAfterLast('/', missingDelimiterValue = "media") }
            .uppercase()
    }

    private fun resolutionLabel(width: Long, height: Long): String {
        if (width <= 0 || height <= 0) {
            return ""
        }
        return "${width}x${height}"
    }

    private fun readSameNameText(path: String, extension: String): String? {
        if (path.isBlank()) {
            return null
        }
        return try {
            val mediaFile = File(path)
            val textFile = File(mediaFile.parentFile, "${mediaFile.nameWithoutExtension}.$extension")
            if (!textFile.isFile || textFile.length() <= 0L || textFile.length() > 256 * 1024) {
                null
            } else {
                textFile.readText(Charsets.UTF_8).ifBlank { null }
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun saveScanSnapshot(
        audioItems: List<Map<String, Any?>>,
        videoItems: List<Map<String, Any?>>,
    ) {
        val root = JSONObject()
            .put("audioItems", audioItems.toJsonArray())
            .put("videoItems", videoItems.toJsonArray())
            .put("updatedAtMs", System.currentTimeMillis())
        snapshotFile().writeText(root.toString())
    }

    private fun snapshotFile(): File {
        return File(filesDir, "media_library_snapshot.json")
    }

    private fun appStateFile(): File {
        return File(filesDir, "echoframe_state.json")
    }

    private fun backupDirectory(): File {
        val documents = getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS) ?: filesDir
        return File(documents, "EchoFrame/backups").apply { mkdirs() }
    }

    private fun latestBackupFile(): File? {
        return backupDirectory()
            .listFiles { file -> file.isFile && file.extension.equals("json", ignoreCase = true) }
            ?.maxByOrNull { it.lastModified() }
    }

    private fun backupInfo(file: File): Map<String, Any?> {
        return mapOf(
            "path" to file.absolutePath,
            "updatedAtMs" to file.lastModified(),
        )
    }

    private fun List<Map<String, Any?>>.toJsonArray(): JSONArray {
        val array = JSONArray()
        forEach { row ->
            val item = JSONObject()
            row.forEach { (key, value) -> item.put(key, value) }
            array.put(item)
        }
        return array
    }

    private fun JSONArray?.toMapList(): List<Map<String, Any?>> {
        if (this == null) {
            return emptyList()
        }
        val items = mutableListOf<Map<String, Any?>>()
        for (index in 0 until length()) {
            val item = optJSONObject(index) ?: continue
            val map = mutableMapOf<String, Any?>()
            item.keys().forEach { key ->
                map[key] = item.opt(key)
            }
            items.add(map)
        }
        return items
    }

    private fun JSONObject.toMap(): Map<String, Any?> {
        val map = mutableMapOf<String, Any?>()
        keys().forEach { key ->
            map[key] = jsonValueToKotlin(opt(key))
        }
        return map
    }

    private fun JSONArray.toList(): List<Any?> {
        val values = mutableListOf<Any?>()
        for (index in 0 until length()) {
            values.add(jsonValueToKotlin(opt(index)))
        }
        return values
    }

    private fun jsonValueToKotlin(value: Any?): Any? {
        return when (value) {
            JSONObject.NULL -> null
            is JSONObject -> value.toMap()
            is JSONArray -> value.toList()
            else -> value
        }
    }

    private data class ScanFilter(
        val minimumAudioDurationMs: Long,
        val includedFolders: List<String>,
        val excludedFolders: List<String>,
    ) {
        fun isIncluded(path: String): Boolean {
            if (includedFolders.isEmpty()) {
                return true
            }
            if (path.isBlank()) {
                return false
            }
            val normalizedPath = path.trim().lowercase()
            return includedFolders.any { folder ->
                val normalizedFolder = folder.trim().lowercase().trimEnd('/')
                normalizedFolder.isNotEmpty() &&
                    (normalizedPath.startsWith("$normalizedFolder/") ||
                        normalizedPath == normalizedFolder)
            }
        }

        fun isExcluded(path: String): Boolean {
            if (path.isBlank() || excludedFolders.isEmpty()) {
                return false
            }
            val normalizedPath = path.trim().lowercase()
            return excludedFolders.any { folder ->
                val normalizedFolder = folder.trim().lowercase()
                normalizedFolder.isNotEmpty() && normalizedPath.contains(normalizedFolder)
            }
        }

        companion object {
            fun from(arguments: Any?): ScanFilter {
                val values = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                val duration = when (val raw = values["minimumAudioDurationMs"]) {
                    is Number -> raw.toLong()
                    else -> raw?.toString()?.toLongOrNull() ?: 45000L
                }
                val includedFolders = (values["includedFolders"] as? List<*>)
                    ?.mapNotNull { it?.toString() }
                    ?.filter { it.isNotBlank() }
                    ?: emptyList()
                val excludedFolders = (values["excludedFolders"] as? List<*>)
                    ?.mapNotNull { it?.toString() }
                    ?.filter { it.isNotBlank() }
                    ?: emptyList()
                return ScanFilter(
                    minimumAudioDurationMs = duration.coerceAtLeast(0L),
                    includedFolders = includedFolders,
                    excludedFolders = excludedFolders,
                )
            }
        }
    }
}
