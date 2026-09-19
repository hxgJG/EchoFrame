package com.hxg.lumio

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.app.RecoverableSecurityException
import android.content.ContentResolver
import android.content.ContentValues
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.MediaMetadata
import android.media.MediaMetadataRetriever
import android.media.audiofx.Equalizer
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Rational
import android.view.Surface
import androidx.core.content.ContextCompat
import androidx.media3.common.MediaItem as Media3MediaItem
import androidx.media3.common.MediaMetadata as Media3MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.mpatric.mp3agic.ID3v24Tag
import com.mpatric.mp3agic.Mp3File
import com.google.common.util.concurrent.ListenableFuture
import com.tencent.mmkv.MMKV
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import org.json.JSONArray
import org.json.JSONObject

private data class PendingMediaFileOperation(
    val type: String,
    val mediaIds: List<String>,
    val displayName: String,
    val relativePath: String,
    val title: String,
    val artist: String,
    val album: String,
    val result: MethodChannel.Result,
)

class MainActivity : FlutterActivity() {
    private data class PendingLyricsExport(
        val result: MethodChannel.Result,
        val bytes: ByteArray,
    )

    private val notificationChannelId = "lumio_playback"
    private val playbackNotificationId = 2408
    private val actionPlayPause = "com.hxg.lumio.PLAY_PAUSE"
    private val actionNext = "com.hxg.lumio.NEXT"
    private val actionPrevious = "com.hxg.lumio.PREVIOUS"
    private val mediaLibraryChannelName = "lumio/media_library"
    private val appStorageChannelName = "lumio/app_storage"
    private val playbackChannelName = "lumio/playback"
    private val appStatePartitions = listOf("session", "library", "playlists")
    private val permissionRequestCode = 2407
    private val fileOperationRequestCode = 2410
    private val lyricsPickerRequestCode = 2411
    private val lyricsExportRequestCode = 2412
    private var pendingLyricsExport: PendingLyricsExport? = null
    private var pendingScanResult: MethodChannel.Result? = null
    private var pendingScanArguments: Any? = null
    private var pendingFileOperation: PendingMediaFileOperation? = null
    private var pendingLyricsImportResult: MethodChannel.Result? = null
    private var playbackChannel: MethodChannel? = null
    private var mediaControllerFuture: ListenableFuture<MediaController>? = null
    private var mediaController: MediaController? = null
    private var completionEventSent = false
    private var flutterTextureRegistry: TextureRegistry? = null
    private var mediaPlayer: MediaPlayer? = null
    private var videoTextureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var videoSurface: Surface? = null
    private var currentPlaybackMediaId: String? = null
    private var currentPlaybackTitle: String = "忆光"
    private var currentPlaybackArtist: String = "本地媒体"
    private var currentPlaybackAlbum: String = ""
    private var currentPlaybackKind: String = ""
    private var isInPipMode = false
    private var playbackSpeed: Float = 1.0f
    private var volumeScale: Float = 1.0f
    private var equalizerPreset: String = "off"
    private var customEqualizerGains: List<Int> = listOf(0, 0, 0, 0, 0)
    private var equalizer: Equalizer? = null
    private var audioManager: AudioManager? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var mediaSession: MediaSession? = null
    private var noisyReceiverRegistered = false
    private val mediaScanExecutor = Executors.newSingleThreadExecutor()
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                pauseForSystem("pause")
            }
        }
    }
    private val audioFocusChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        when (focusChange) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                playbackChannel?.invokeMethod("interruptionEnded", null)
            }

            AudioManager.AUDIOFOCUS_LOSS -> {
                pauseForSystem("interruptionBegan", mayResume = false)
            }

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
            -> pauseForSystem("interruptionBegan", mayResume = true)
        }
    }
    private val mediaControllerListener = object : Player.Listener {
        override fun onMediaItemTransition(mediaItem: Media3MediaItem?, reason: Int) {
            val mediaId = mediaItem?.mediaId.orEmpty()
            if (mediaId.isBlank()) {
                return
            }
            completionEventSent = false
            currentPlaybackMediaId = mediaId
            currentPlaybackKind = mediaItem?.mediaMetadata?.extras
                ?.getString("kind")
                .orEmpty()
            playbackChannel?.invokeMethod(
                "mediaItemChanged",
                mapOf("mediaId" to mediaId),
            )
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            updatePictureInPictureParams(isPlaying)
            playbackChannel?.invokeMethod(
                "nativePlaybackStateChanged",
                mapOf("isPlaying" to isPlaying),
            )
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            if (playbackState != Player.STATE_ENDED || completionEventSent) {
                return
            }
            completionEventSent = true
            playbackChannel?.invokeMethod(
                "completed",
                mapOf("mediaId" to currentPlaybackMediaId),
            )
        }

        override fun onPlayerError(error: PlaybackException) {
            playbackChannel?.invokeMethod(
                "error",
                mapOf(
                    "mediaId" to currentPlaybackMediaId,
                    "message" to (error.message ?: "Media3 playback failed."),
                ),
            )
        }

        override fun onAudioSessionIdChanged(audioSessionId: Int) {
            applyEqualizer(audioSessionId)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MMKV.initialize(this)
        flutterTextureRegistry = flutterEngine.renderer
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mediaLibraryChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scan" -> scanMediaLibrary(call.arguments, result)
                    "restoreLastScan" -> restoreLastScan(result)
                    "loadArtwork" -> loadArtwork(call.arguments, result)
                    "performFileOperation" -> performMediaFileOperation(call.arguments, result)
                    "importLyrics" -> importLyrics(result)
                    "exportLyrics" -> exportLyrics(call.arguments, result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, appStorageChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "loadPartition" -> loadAppStatePartition(call.arguments, result)
                    "savePartition" -> saveAppStatePartition(call.arguments, result)
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
                "setCrossfadeDuration" -> setCrossfadeDuration(call.arguments, result)
                "setShuffleEnabled" -> setShuffleEnabled(call.arguments, result)
                "setRepeatMode" -> setRepeatMode(call.arguments, result)
                "stop" -> stopMedia(result)
                "position" -> playbackPosition(result)
                "enterPictureInPicture" -> enterPip(result)
                "adjustBrightness" -> adjustBrightness(call.arguments, result)
                "adjustVolume" -> adjustVolume(call.arguments, result)
                "share" -> shareMedia(call.arguments, result)
                "shareMany" -> shareManyMedia(call.arguments, result)
                else -> result.notImplemented()
            }
        }
        initializeMediaController()
    }

    private fun initializeMediaController() {
        val token = SessionToken(
            this,
            ComponentName(this, LumioPlaybackService::class.java),
        )
        val future = MediaController.Builder(this, token).buildAsync()
        mediaControllerFuture = future
        future.addListener(
            {
                try {
                    attachMediaController(future.get())
                } catch (_: Exception) {
                    // Method channel calls surface initialization failures to Flutter.
                }
            },
            ContextCompat.getMainExecutor(this),
        )
    }

    private fun attachMediaController(controller: MediaController) {
        if (mediaController === controller) {
            return
        }
        mediaController?.removeListener(mediaControllerListener)
        mediaController = controller
        controller.addListener(mediaControllerListener)
        controller.currentMediaItem?.let {
            mediaControllerListener.onMediaItemTransition(
                it,
                Player.MEDIA_ITEM_TRANSITION_REASON_PLAYLIST_CHANGED,
            )
        }
        mediaControllerListener.onIsPlayingChanged(controller.isPlaying)
    }

    private fun withMediaController(
        result: MethodChannel.Result,
        errorCode: String,
        action: (MediaController) -> Any?,
    ) {
        val current = mediaController
        if (current != null) {
            completeControllerAction(result, errorCode, current, action)
            return
        }
        val future = mediaControllerFuture
        if (future == null) {
            result.error(errorCode, "Media3 controller is unavailable.", null)
            return
        }
        future.addListener(
            {
                try {
                    val controller = future.get()
                    attachMediaController(controller)
                    completeControllerAction(result, errorCode, controller, action)
                } catch (error: Exception) {
                    result.error(
                        errorCode,
                        error.cause?.message ?: error.message ?: "Media3 controller failed.",
                        null,
                    )
                }
            },
            ContextCompat.getMainExecutor(this),
        )
    }

    private fun completeControllerAction(
        result: MethodChannel.Result,
        errorCode: String,
        controller: MediaController,
        action: (MediaController) -> Any?,
    ) {
        try {
            result.success(action(controller))
        } catch (error: Exception) {
            result.error(errorCode, error.message ?: "Media3 operation failed.", null)
        }
    }

    private fun mediaUri(path: String): Uri {
        val parsed = Uri.parse(path)
        return if (parsed.scheme.isNullOrBlank()) Uri.fromFile(File(path)) else parsed
    }

    private fun shareMedia(arguments: Any?, result: MethodChannel.Result) {
        try {
            val values = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
            val mediaId = values["mediaId"]?.toString().orEmpty()
            val kind = values["kind"]?.toString().orEmpty()
            val title = values["title"]?.toString().orEmpty().ifBlank { "忆光媒体" }
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

    private fun shareManyMedia(arguments: Any?, result: MethodChannel.Result) {
        try {
            val values = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
            val items = values["items"] as? List<*> ?: emptyList<Any?>()
            val uris = ArrayList<Uri>()
            items.forEach { rawItem ->
                val item = rawItem as? Map<*, *> ?: return@forEach
                val mediaId = item["mediaId"]?.toString().orEmpty()
                val kind = item["kind"]?.toString().orEmpty()
                mediaStoreUri(mediaId, kind)?.let { uris.add(it) }
            }
            if (uris.isEmpty()) {
                result.error("shareUnsupported", "没有可分享的 Android 媒体库文件。", null)
                return
            }
            val intent = Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                type = "*/*"
                putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
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

    private fun mediaStoreUri(mediaId: String): Uri? {
        val kind = when {
            mediaId.contains("-audio-") -> "audio"
            mediaId.contains("-video-") -> "video"
            else -> return null
        }
        return mediaStoreUri(mediaId, kind)
    }

    private fun performMediaFileOperation(arguments: Any?, result: MethodChannel.Result) {
        if (pendingFileOperation != null) {
            result.error("operationInProgress", "已有文件操作正在等待系统授权。", null)
            return
        }
        val values = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        val type = values["type"]?.toString().orEmpty()
        val mediaIds = (values["mediaIds"] as? List<*>)
            ?.mapNotNull { it?.toString()?.takeIf(String::isNotBlank) }
            ?.distinct()
            .orEmpty()
        val displayName = values["displayName"]?.toString()?.trim().orEmpty()
        val relativePath = values["relativePath"]?.toString()?.trim().orEmpty()
        val title = values["title"]?.toString()?.trim().orEmpty()
        val artist = values["artist"]?.toString()?.trim().orEmpty()
        val album = values["album"]?.toString()?.trim().orEmpty()
        if (
            mediaIds.isEmpty() ||
            type !in setOf("rename", "move", "writeTags") ||
            (type == "rename" && (mediaIds.size != 1 || !isSafeDisplayName(displayName))) ||
            (type == "move" && !isSafeRelativePath(relativePath)) ||
            (type == "writeTags" && (
                mediaIds.size != 1 ||
                    listOf(title, artist, album).all(String::isBlank)
                ))
        ) {
            result.success(fileOperationResult("failed", "文件操作参数无效。"))
            return
        }
        val uris = mediaIds.mapNotNull(::mediaStoreUri)
        if (uris.size != mediaIds.size) {
            result.success(fileOperationResult("failed", "只能操作 Android MediaStore 中的媒体。"))
            return
        }
        val pending = PendingMediaFileOperation(
            type = type,
            mediaIds = mediaIds,
            displayName = displayName,
            relativePath = relativePath,
            title = title,
            artist = artist,
            album = album,
            result = result,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            requestMediaStoreApproval(pending, uris)
            return
        }
        try {
            completeMediaFileOperation(pending, uris)
        } catch (error: RecoverableSecurityException) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                pendingFileOperation = pending
                startIntentSenderForResult(
                    error.userAction.actionIntent.intentSender,
                    fileOperationRequestCode,
                    null,
                    0,
                    0,
                    0,
                )
            } else {
                result.success(
                    fileOperationResult(
                        "failed",
                        error.message ?: "系统拒绝了文件操作。",
                    ),
                )
            }
        } catch (error: Exception) {
            result.success(
                fileOperationResult(
                    "failed",
                    error.message ?: "文件操作失败。",
                ),
            )
        }
    }

    private fun requestMediaStoreApproval(
        operation: PendingMediaFileOperation,
        uris: List<Uri>,
    ) {
        try {
            val pendingIntent = MediaStore.createWriteRequest(contentResolver, uris)
            pendingFileOperation = operation
            startIntentSenderForResult(
                pendingIntent.intentSender,
                fileOperationRequestCode,
                null,
                0,
                0,
                0,
            )
        } catch (error: Exception) {
            pendingFileOperation = null
            operation.result.success(
                fileOperationResult(
                    "failed",
                    error.message ?: "无法启动系统文件授权。",
                ),
            )
        }
    }

    private fun completeMediaFileOperation(
        operation: PendingMediaFileOperation,
        uris: List<Uri> = operation.mediaIds.mapNotNull(::mediaStoreUri),
    ) {
        val affectedIds = mutableListOf<String>()
        operation.mediaIds.zip(uris).forEach { (mediaId, uri) ->
            val changed = when (operation.type) {
                "rename" -> contentResolver.update(
                    uri,
                    ContentValues().apply {
                        put(MediaStore.MediaColumns.DISPLAY_NAME, operation.displayName)
                    },
                    null,
                    null,
                )
                "move" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                        0
                    } else {
                        contentResolver.update(
                            uri,
                            ContentValues().apply {
                                put(MediaStore.MediaColumns.RELATIVE_PATH, operation.relativePath)
                            },
                            null,
                            null,
                        )
                    }
                }
                "writeTags" -> writeMp3Tags(
                    uri,
                    title = operation.title,
                    artist = operation.artist,
                    album = operation.album,
                )
                else -> 0
            }
            if (changed > 0) {
                affectedIds.add(mediaId)
            }
        }
        val status = if (affectedIds.isNotEmpty()) "completed" else "failed"
        val message = when {
            affectedIds.isEmpty() -> "没有媒体文件被修改。"
            operation.type == "rename" -> "文件已重命名。"
            operation.type == "writeTags" -> "MP3 标签已写入源文件。"
            else -> "已移动 ${affectedIds.size} 个媒体文件。"
        }
        operation.result.success(fileOperationResult(status, message, affectedIds))
    }

    private fun fileOperationResult(
        status: String,
        message: String,
        affectedMediaIds: List<String> = emptyList(),
    ): Map<String, Any?> {
        return mapOf(
            "status" to status,
            "message" to message,
            "affectedMediaIds" to affectedMediaIds,
        )
    }

    private fun isSafeDisplayName(value: String): Boolean {
        return value.isNotBlank() &&
            value !in setOf(".", "..") &&
            !value.contains('/') &&
            !value.contains('\\')
    }

    private fun isSafeRelativePath(value: String): Boolean {
        if (value.isBlank() || value.startsWith('/') || value.contains('\\')) {
            return false
        }
        return value.split('/')
            .filter(String::isNotBlank)
            .all { it !in setOf(".", "..") }
    }

    private fun writeMp3Tags(
        uri: Uri,
        title: String,
        artist: String,
        album: String,
    ): Int {
        val displayName = mediaDisplayName(uri)
        if (!displayName.endsWith(".mp3", ignoreCase = true)) {
            throw IllegalArgumentException("当前仅支持写入 MP3 标签。")
        }
        val token = System.nanoTime().toString()
        val inputFile = File(cacheDir, "lumio-tag-$token-input.mp3")
        val outputFile = File(cacheDir, "lumio-tag-$token-output.mp3")
        try {
            contentResolver.openInputStream(uri)?.use { input ->
                inputFile.outputStream().use(input::copyTo)
            } ?: throw IllegalStateException("无法读取 MP3 文件。")
            val mp3File = Mp3File(inputFile.absolutePath)
            val tag = if (mp3File.hasId3v2Tag()) {
                mp3File.id3v2Tag
            } else {
                ID3v24Tag().also { mp3File.id3v2Tag = it }
            }
            if (title.isNotBlank()) {
                tag.title = title
            }
            if (artist.isNotBlank()) {
                tag.artist = artist
            }
            if (album.isNotBlank()) {
                tag.album = album
            }
            mp3File.save(outputFile.absolutePath)
            try {
                contentResolver.openOutputStream(uri, "rwt")?.use { output ->
                    outputFile.inputStream().use { it.copyTo(output) }
                } ?: throw IllegalStateException("无法写入 MP3 文件。")
            } catch (error: Exception) {
                contentResolver.openOutputStream(uri, "rwt")?.use { output ->
                    inputFile.inputStream().use { it.copyTo(output) }
                }
                throw error
            }
            contentResolver.update(
                uri,
                ContentValues().apply {
                    if (title.isNotBlank()) {
                        put(MediaStore.Audio.Media.TITLE, title)
                    }
                    if (artist.isNotBlank()) {
                        put(MediaStore.Audio.Media.ARTIST, artist)
                    }
                    if (album.isNotBlank()) {
                        put(MediaStore.Audio.Media.ALBUM, album)
                    }
                },
                null,
                null,
            )
            return 1
        } finally {
            inputFile.delete()
            outputFile.delete()
        }
    }

    private fun mediaDisplayName(uri: Uri): String {
        return contentResolver.query(
            uri,
            arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0).orEmpty() else ""
        }.orEmpty()
    }

    private fun createAppBackup(arguments: Any?, result: MethodChannel.Result) {
        try {
            val value = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
            val text = JSONObject(value).toString()
            saveAppStatePartitions(value)
            val file = File(backupDirectory(), "lumio-backup-${System.currentTimeMillis()}.json")
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
            val value = LumioMetadataRepair.library(JSONObject(text).toMap())
            saveAppStatePartitions(value)
            result.success(value)
        } catch (error: Exception) {
            result.error("restoreFailed", error.message ?: "Restore backup failed.", null)
        }
    }

    private fun latestBackup(result: MethodChannel.Result) {
        result.success(latestBackupFile()?.let { backupInfo(it) })
    }

    override fun onDestroy() {
        pendingLyricsExport?.result?.success(mapOf("status" to "cancelled", "message" to "应用已关闭，导出中断。"))
        pendingLyricsExport = null
        pendingFileOperation?.result?.success(
            fileOperationResult("cancelled", "Activity 已关闭，文件操作未完成。"),
        )
        pendingFileOperation = null
        pendingLyricsImportResult?.success(
            lyricsImportResult("cancelled", "Activity 已关闭，歌词导入未完成。"),
        )
        pendingLyricsImportResult = null
        equalizer?.release()
        equalizer = null
        releaseVideoSurface()
        mediaController?.removeListener(mediaControllerListener)
        mediaController = null
        mediaControllerFuture?.let(MediaController::releaseFuture)
        mediaControllerFuture = null
        flutterTextureRegistry = null
        playbackChannel = null
        mediaScanExecutor.shutdownNow()
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handlePlaybackIntent(intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == lyricsExportRequestCode) {
            completeLyricsExport(resultCode, data)
            return
        }
        if (requestCode == lyricsPickerRequestCode) {
            completeLyricsImport(resultCode, data)
            return
        }
        if (requestCode != fileOperationRequestCode) {
            return
        }
        val operation = pendingFileOperation ?: return
        pendingFileOperation = null
        if (resultCode != Activity.RESULT_OK) {
            operation.result.success(
                fileOperationResult("cancelled", "已取消系统文件授权。"),
            )
            return
        }
        try {
            completeMediaFileOperation(operation)
        } catch (error: Exception) {
            operation.result.success(
                fileOperationResult(
                    "failed",
                    error.message ?: "文件操作失败。",
                ),
            )
        }
    }

    private fun importLyrics(result: MethodChannel.Result) {
        if (pendingLyricsImportResult != null) {
            result.success(lyricsImportResult("failed", "已有歌词文件正在选择中。"))
            return
        }
        pendingLyricsImportResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        try {
            startActivityForResult(
                Intent.createChooser(intent, "选择 LRC 歌词文件"),
                lyricsPickerRequestCode,
            )
        } catch (error: Exception) {
            pendingLyricsImportResult = null
            result.success(
                lyricsImportResult(
                    "failed",
                    error.message ?: "无法打开歌词文件选择器。",
                ),
            )
        }
    }

    private fun exportLyrics(arguments: Any?, result: MethodChannel.Result) {
        if (pendingLyricsExport != null) {
            result.success(mapOf("status" to "failed", "message" to "已有歌词正在导出。"))
            return
        }
        val args = arguments as? Map<*, *>
        val name = args?.get("fileName") as? String
        val bytes = args?.get("bytes") as? ByteArray
        if (name == null || name.contains('/') || name.contains('\\') ||
            (!name.endsWith(".lrc") && !name.endsWith(".zip")) ||
            bytes == null || bytes.isEmpty() || bytes.size > 32 * 1024 * 1024) {
            result.success(mapOf("status" to "failed", "message" to "歌词导出内容无效或超过 32 MB。"))
            return
        }
        pendingLyricsExport = PendingLyricsExport(result, bytes)
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (name.endsWith(".zip")) "application/zip" else "application/octet-stream"
            putExtra(Intent.EXTRA_TITLE, name)
        }
        try {
            startActivityForResult(intent, lyricsExportRequestCode)
        } catch (error: Exception) {
            pendingLyricsExport = null
            result.success(mapOf("status" to "failed", "message" to (error.message ?: "无法打开系统保存界面。")))
        }
    }

    private fun completeLyricsExport(resultCode: Int, data: Intent?) {
        val pending = pendingLyricsExport ?: return
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pendingLyricsExport = null
            pending.result.success(mapOf("status" to "cancelled", "message" to "已取消导出。"))
            return
        }
        mediaScanExecutor.execute {
            val response = try {
                val stream = contentResolver.openOutputStream(uri, "wt")
                    ?: throw java.io.IOException("无法打开目标文件。")
                stream.use { it.write(pending.bytes) }
                mapOf("status" to "completed", "message" to "歌词已保存。")
            } catch (error: Exception) {
                mapOf("status" to "failed", "message" to (error.message ?: "歌词保存失败，请重试。"))
            }
            runOnUiThread {
                if (pendingLyricsExport === pending) {
                    pendingLyricsExport = null
                    pending.result.success(response)
                }
            }
        }
    }

    private fun completeLyricsImport(resultCode: Int, data: Intent?) {
        val result = pendingLyricsImportResult ?: return
        pendingLyricsImportResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(lyricsImportResult("cancelled", "已取消选择歌词文件。"))
            return
        }
        val uri = data.data!!
        mediaScanExecutor.execute {
            val response = try {
                val fileName = queryDisplayName(uri)
                if (!fileName.endsWith(".lrc", ignoreCase = true)) {
                    lyricsImportResult("failed", "请选择 .lrc 格式的歌词文件。")
                } else {
                    val text = readLyricsText(uri)
                    lyricsImportResult(
                        status = "completed",
                        message = "歌词文件已读取。",
                        fileName = fileName,
                        lyricsText = text,
                    )
                }
            } catch (error: Exception) {
                lyricsImportResult(
                    "failed",
                    error.message ?: "歌词文件读取失败。",
                )
            }
            runOnUiThread { result.success(response) }
        }
    }

    private fun queryDisplayName(uri: Uri): String {
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (index >= 0 && cursor.moveToFirst()) {
                cursor.getString(index)?.takeIf(String::isNotBlank)?.let { return it }
            }
        }
        return uri.lastPathSegment.orEmpty()
    }

    private fun readLyricsText(uri: Uri): String {
        val maximumBytes = 2 * 1024 * 1024
        val input = contentResolver.openInputStream(uri)
            ?: throw IllegalStateException("无法打开歌词文件。")
        return input.use { stream ->
            ByteArrayOutputStream().use { output ->
                val buffer = ByteArray(8192)
                var totalBytes = 0
                while (true) {
                    val read = stream.read(buffer)
                    if (read < 0) break
                    totalBytes += read
                    if (totalBytes > maximumBytes) {
                        throw IllegalArgumentException("歌词文件不能超过 2 MB。")
                    }
                    output.write(buffer, 0, read)
                }
                val bytes = output.toByteArray()
                when {
                    bytes.size >= 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xFE.toByte() ->
                        String(bytes, 2, bytes.size - 2, Charsets.UTF_16LE)
                    bytes.size >= 2 && bytes[0] == 0xFE.toByte() && bytes[1] == 0xFF.toByte() ->
                        String(bytes, 2, bytes.size - 2, Charsets.UTF_16BE)
                    else -> String(bytes, Charsets.UTF_8).removePrefix("\uFEFF")
                }
            }
        }
    }

    private fun lyricsImportResult(
        status: String,
        message: String,
        fileName: String = "",
        lyricsText: String = "",
    ): Map<String, Any> = mapOf(
        "status" to status,
        "message" to message,
        "fileName" to fileName,
        "lyricsText" to lyricsText,
    )

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (
            Build.VERSION.SDK_INT in Build.VERSION_CODES.O until Build.VERSION_CODES.S &&
            currentPlaybackKind == "video" &&
            mediaController?.isPlaying == true &&
            !isInPipMode
        ) {
            enterPipInternal()
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        isInPipMode = isInPictureInPictureMode
        playbackChannel?.invokeMethod(
            "pipModeChanged",
            mapOf("isInPictureInPicture" to isInPictureInPictureMode),
        )
    }

    private fun scanMediaLibrary(arguments: Any?, result: MethodChannel.Result) {
        if (!hasMediaPermissions()) {
            pendingScanResult = result
            pendingScanArguments = arguments
            requestPermissions(requiredMediaPermissions(), permissionRequestCode)
            return
        }

        val filter = ScanFilter.from(arguments)
        mediaScanExecutor.execute {
            val response = try {
                val audioItems = queryAudio(filter)
                val videoItems = queryVideo(filter)
                saveScanSnapshot(audioItems, videoItems)
                mapOf(
                    "status" to "completed",
                    "audioItems" to audioItems,
                    "videoItems" to videoItems,
                )
            } catch (error: Exception) {
                mapOf(
                    "status" to "failed",
                    "message" to (error.message ?: "MediaStore scan failed."),
                    "audioItems" to emptyList<Map<String, Any?>>(),
                    "videoItems" to emptyList<Map<String, Any?>>(),
                )
            }
            runOnUiThread {
                result.success(response)
            }
        }
    }

    private fun loadArtwork(arguments: Any?, result: MethodChannel.Result) {
        val values = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        val mediaId = values["mediaId"]?.toString().orEmpty()
        val kind = values["kind"]?.toString().orEmpty()
        val uri = mediaStoreUri(mediaId, kind)
        if (uri == null) {
            result.success(null)
            return
        }
        mediaScanExecutor.execute {
            val bytes = extractArtworkBytes(uri, kind)
            runOnUiThread {
                result.success(bytes)
            }
        }
    }

    private fun extractArtworkBytes(uri: Uri, kind: String): ByteArray? {
        val retriever = MediaMetadataRetriever()
        var bitmap: Bitmap? = null
        return try {
            retriever.setDataSource(this, uri)
            bitmap = if (kind == "audio") {
                retriever.embeddedPicture?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
            } else {
                retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            }
            val source = bitmap ?: return null
            val scaled = scaleArtworkBitmap(source, 512)
            ByteArrayOutputStream().use { output ->
                scaled.compress(Bitmap.CompressFormat.JPEG, 84, output)
                output.toByteArray()
            }.also {
                if (scaled !== source) {
                    scaled.recycle()
                }
            }
        } catch (_: Exception) {
            null
        } finally {
            bitmap?.recycle()
            retriever.release()
        }
    }

    private fun scaleArtworkBitmap(source: Bitmap, maxEdge: Int): Bitmap {
        val largestEdge = maxOf(source.width, source.height)
        if (largestEdge <= maxEdge) {
            return source
        }
        val scale = maxEdge.toFloat() / largestEdge.toFloat()
        return Bitmap.createScaledBitmap(
            source,
            (source.width * scale).toInt().coerceAtLeast(1),
            (source.height * scale).toInt().coerceAtLeast(1),
            true,
        )
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
                    "audioItems" to root.optJSONArray("audioItems").toMapList().map(LumioMetadataRepair::record),
                    "videoItems" to root.optJSONArray("videoItems").toMapList().map(LumioMetadataRepair::record),
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

    private fun loadAppStatePartition(arguments: Any?, result: MethodChannel.Result) {
        val values = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        val partition = values["partition"]?.toString().orEmpty()
        val text = if (partition in appStatePartitions) {
            appStateStorage().decodeString(partitionKey(partition))
        } else {
            null
        }
        if (text.isNullOrBlank()) {
            result.success(null)
            return
        }

        try {
            result.success(LumioMetadataRepair.library(JSONObject(text).toMap()))
        } catch (error: Exception) {
            result.success(null)
        }
    }

    private fun saveAppStatePartition(arguments: Any?, result: MethodChannel.Result) {
        try {
            val values = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
            val partition = values["partition"]?.toString().orEmpty()
            if (partition !in appStatePartitions) {
                result.error("invalidPartition", "Unknown app storage partition.", null)
                return
            }
            val value = values["value"] as? Map<*, *> ?: emptyMap<String, Any?>()
            appStateStorage().encode(partitionKey(partition), JSONObject(value).toString())
            result.success(null)
        } catch (error: Exception) {
            result.error("saveFailed", error.message ?: "Save app state failed.", null)
        }
    }

    private fun playMedia(arguments: Any?, result: MethodChannel.Result) {
        val values = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        val rawItems = values["items"] as? List<*> ?: emptyList<Any?>()
        val mediaItems = rawItems.mapNotNull { raw ->
            val item = raw as? Map<*, *> ?: return@mapNotNull null
            val path = item["path"]?.toString().orEmpty()
            val mediaId = item["mediaId"]?.toString().orEmpty()
            if (path.isBlank() || mediaId.isBlank()) {
                return@mapNotNull null
            }
            val kind = item["kind"]?.toString().orEmpty()
            val extras = Bundle().apply { putString("kind", kind) }
            Media3MediaItem.Builder()
                .setMediaId(mediaId)
                .setUri(mediaUri(path))
                .setMediaMetadata(
                    Media3MediaMetadata.Builder()
                        .setTitle(item["title"]?.toString().orEmpty().ifBlank { "忆光" })
                        .setArtist(
                            item["artist"]?.toString().orEmpty().ifBlank { "本地媒体" },
                        )
                        .setAlbumTitle(item["album"]?.toString().orEmpty())
                        .setExtras(extras)
                        .build(),
                )
                .build()
        }
        val currentIndex = ((values["currentIndex"] as? Number)?.toInt()
            ?: values["currentIndex"]?.toString()?.toIntOrNull()
            ?: 0).coerceIn(0, (mediaItems.size - 1).coerceAtLeast(0))
        val startPositionMs = (values["positionMs"] as? Number)?.toLong()
            ?: values["positionMs"]?.toString()?.toLongOrNull()
            ?: 0L
        if (mediaItems.isEmpty()) {
            result.error("invalidQueue", "Media3 queue is empty.", null)
            return
        }

        val current = mediaItems[currentIndex]
        currentPlaybackMediaId = current.mediaId
        currentPlaybackTitle = current.mediaMetadata.title?.toString().orEmpty()
        currentPlaybackArtist = current.mediaMetadata.artist?.toString().orEmpty()
        currentPlaybackAlbum = current.mediaMetadata.albumTitle?.toString().orEmpty()
        currentPlaybackKind = current.mediaMetadata.extras?.getString("kind").orEmpty()
        completionEventSent = false
        val textureId = if (currentPlaybackKind == "video") {
            prepareVideoSurface()
        } else {
            releaseVideoSurface()
            null
        }
        withMediaController(result, "playFailed") { controller ->
            if (currentPlaybackKind == "video") {
                videoSurface?.let(controller::setVideoSurface)
            } else {
                controller.clearVideoSurface()
            }
            controller.setMediaItems(mediaItems, currentIndex, startPositionMs.coerceAtLeast(0L))
            controller.setPlaybackSpeed(playbackSpeed)
            controller.volume = volumeScale
            controller.prepare()
            controller.play()
            applyEqualizer(controller.audioSessionId)
            updatePictureInPictureParams(true)
            ensureNotificationPermission()
            mapOf("textureId" to textureId)
        }
    }

    private fun setPlaybackSpeed(arguments: Any?, result: MethodChannel.Result) {
        val values = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        val speed = (values["speed"] as? Number)?.toFloat()
            ?: values["speed"]?.toString()?.toFloatOrNull()
            ?: 1.0f
        playbackSpeed = speed.coerceIn(0.5f, 2.0f)
        withMediaController(result, "speedFailed") { controller ->
            controller.setPlaybackSpeed(playbackSpeed)
            null
        }
    }

    private fun setEqualizerPreset(arguments: Any?, result: MethodChannel.Result) {
        val values = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        equalizerPreset = values["preset"]?.toString().orEmpty().ifBlank { "off" }
        customEqualizerGains = intListArgument(values["customGains"])
        withMediaController(result, "equalizerFailed") { controller ->
            applyEqualizer(controller.audioSessionId)
            null
        }
    }

    private fun setVolumeScale(arguments: Any?, result: MethodChannel.Result) {
        volumeScale = doubleArgument(arguments, "scale").toFloat().coerceIn(0f, 1f)
        withMediaController(result, "volumeScaleFailed") { controller ->
            controller.volume = volumeScale
            null
        }
    }

    private fun setCrossfadeDuration(arguments: Any?, result: MethodChannel.Result) {
        val values = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        val durationMs = (values["durationMs"] as? Number)?.toLong()
            ?: values["durationMs"]?.toString()?.toLongOrNull()
            ?: 0L
        withMediaController(result, "crossfadeFailed") {
            LumioPlaybackService.updateCrossfadeDuration(durationMs)
            null
        }
    }

    private fun pauseMedia(result: MethodChannel.Result) {
        withMediaController(result, "pauseFailed") { controller ->
            controller.pause()
            updatePictureInPictureParams(false)
            null
        }
    }

    private fun resumeMedia(result: MethodChannel.Result) {
        withMediaController(result, "resumeFailed") { controller ->
            controller.play()
            updatePictureInPictureParams(true)
            null
        }
    }

    private fun seekMedia(arguments: Any?, result: MethodChannel.Result) {
        val values = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        val positionMs = (values["positionMs"] as? Number)?.toInt()
            ?: values["positionMs"]?.toString()?.toIntOrNull()
            ?: 0
        withMediaController(result, "seekFailed") { controller ->
            controller.seekTo(positionMs.coerceAtLeast(0).toLong())
            null
        }
    }

    private fun setShuffleEnabled(arguments: Any?, result: MethodChannel.Result) {
        val values = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        withMediaController(result, "shuffleFailed") { controller ->
            controller.shuffleModeEnabled = values["enabled"] == true
            null
        }
    }

    private fun setRepeatMode(arguments: Any?, result: MethodChannel.Result) {
        val values = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        val repeatMode = when (values["mode"]?.toString()) {
            "one" -> Player.REPEAT_MODE_ONE
            "all" -> Player.REPEAT_MODE_ALL
            else -> Player.REPEAT_MODE_OFF
        }
        withMediaController(result, "repeatFailed") { controller ->
            controller.repeatMode = repeatMode
            null
        }
    }

    private fun stopMedia(result: MethodChannel.Result) {
        volumeScale = 1.0f
        updatePictureInPictureParams(false)
        currentPlaybackKind = ""
        releaseVideoSurface()
        withMediaController(result, "stopFailed") { controller ->
            controller.stop()
            controller.clearMediaItems()
            null
        }
    }

    private fun playbackPosition(result: MethodChannel.Result) {
        withMediaController(result, "positionFailed") { controller ->
            controller.currentPosition
        }
    }

    private fun enterPip(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(false)
            return
        }
        if (currentPlaybackKind != "video") {
            result.success(false)
            return
        }
        try {
            result.success(enterPipInternal())
        } catch (error: Exception) {
            result.error("pipFailed", error.message ?: "Enter PiP failed.", null)
        }
    }

    private fun enterPipInternal(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || isInPipMode) {
            return false
        }
        return enterPictureInPictureMode(
            buildPictureInPictureParams(mediaController?.isPlaying == true),
        )
    }

    private fun updatePictureInPictureParams(isPlaying: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || currentPlaybackKind != "video") {
            return
        }
        setPictureInPictureParams(buildPictureInPictureParams(isPlaying))
    }

    private fun buildPictureInPictureParams(isPlaying: Boolean): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(16, 9))
            .setActions(pictureInPictureActions(isPlaying))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(currentPlaybackKind == "video" && isPlaying)
            builder.setSeamlessResizeEnabled(true)
        }
        return builder.build()
    }

    private fun pictureInPictureActions(isPlaying: Boolean): List<RemoteAction> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return emptyList()
        }
        val playPauseTitle = if (isPlaying) "暂停" else "播放"
        val playPauseIcon = if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
        return listOf(
            RemoteAction(
                Icon.createWithResource(this, android.R.drawable.ic_media_previous),
                "上一首",
                "上一首",
                playbackActionIntent(actionPrevious, 11),
            ),
            RemoteAction(
                Icon.createWithResource(this, playPauseIcon),
                playPauseTitle,
                playPauseTitle,
                playbackActionIntent(actionPlayPause, 12),
            ),
            RemoteAction(
                Icon.createWithResource(this, android.R.drawable.ic_media_next),
                "下一首",
                "下一首",
                playbackActionIntent(actionNext, 13),
            ),
        )
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

    private fun pauseForSystem(method: String, mayResume: Boolean? = null) {
        try {
            mediaPlayer?.takeIf { it.isPlaying }?.pause()
            updatePlaybackState(false)
            updatePictureInPictureParams(false)
            showPlaybackNotification(false)
            playbackChannel?.invokeMethod(
                method,
                mayResume?.let { mapOf("mayResume" to it) },
            )
        } catch (_: Exception) {
            playbackChannel?.invokeMethod(
                method,
                mayResume?.let { mapOf("mayResume" to it) },
            )
        }
    }

    private fun setupMediaSession() {
        mediaSession = MediaSession(this, "Lumio").apply {
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

    private fun updateMediaSessionMetadata() {
        mediaSession?.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, currentPlaybackTitle)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, currentPlaybackArtist)
                .putString(MediaMetadata.METADATA_KEY_ALBUM, currentPlaybackAlbum)
                .putLong(
                    MediaMetadata.METADATA_KEY_DURATION,
                    mediaPlayer?.duration?.toLong() ?: 0L,
                )
                .build(),
        )
    }

    private fun ensureNotificationPermission() {
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2409)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            notificationChannelId,
            "忆光播放",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "本地媒体播放控制"
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
        val playPauseTitle = if (isPlaying) "暂停" else "播放"
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
                    .ifBlank { "忆光" },
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
                "上一首",
                playbackActionIntent(actionPrevious, 1),
            )
            .addAction(
                playPauseIcon,
                playPauseTitle,
                playbackActionIntent(actionPlayPause, 2),
            )
            .addAction(
                android.R.drawable.ic_media_next,
                "下一首",
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
                val controller = mediaController
                if (controller?.isPlaying == true) {
                    controller.pause()
                } else {
                    controller?.play()
                }
            }
            actionNext -> mediaController?.seekToNextMediaItem()
            actionPrevious -> mediaController?.seekToPreviousMediaItem()
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
        releaseVideoSurface()
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

    private fun releaseVideoSurface() {
        mediaController?.clearVideoSurface()
        videoSurface?.release()
        videoSurface = null
        videoTextureEntry?.release()
        videoTextureEntry = null
        playbackChannel?.invokeMethod(
            "videoTextureChanged",
            mapOf("textureId" to null),
        )
    }

    private fun applyPlaybackSpeed(player: MediaPlayer) {
        player.playbackParams = player.playbackParams.setSpeed(playbackSpeed)
    }

    private fun applyVolumeScale(player: MediaPlayer) {
        player.setVolume(volumeScale, volumeScale)
    }

    private fun applyEqualizer(player: MediaPlayer) {
        applyEqualizer(player.audioSessionId)
    }

    private fun applyEqualizer(audioSessionId: Int) {
        equalizer?.release()
        equalizer = null
        if (equalizerPreset == "off" || audioSessionId <= 0) {
            return
        }
        equalizer = Equalizer(0, audioSessionId).apply {
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
        releaseVideoSurface()
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
            "artist" to cursor.string(MediaStore.Audio.Media.ARTIST).ifBlank { "未知艺术家" },
            "album" to cursor.string(MediaStore.Audio.Media.ALBUM).ifBlank { "未知专辑" },
            "durationMs" to cursor.long(MediaStore.Audio.Media.DURATION),
            "addedAtMs" to cursor.long(MediaStore.Audio.Media.DATE_ADDED) * 1000,
            "path" to path,
            "folder" to File(path).parent.orEmpty(),
            "sizeBytes" to cursor.long(MediaStore.Audio.Media.SIZE),
            "format" to formatLabel(mimeType, path),
        )
        readSameNameText(path, "lrc")?.let { row["lyricsText"] = it }
        return LumioMetadataRepair.record(row)
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
            "artist" to "相机胶卷",
            "album" to File(path).parentFile?.name.orEmpty().ifBlank { "视频" },
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
        return LumioMetadataRepair.record(row)
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

    private fun appStateStorage(): MMKV {
        return MMKV.defaultMMKV()
    }

    private fun partitionKey(partition: String): String {
        return "state_$partition"
    }

    private fun saveAppStatePartitions(value: Map<*, *>) {
        val libraryKeys = setOf("schemaVersion", "audioItems", "videoItems")
        val playlistKeys = setOf("schemaVersion", "playlists")
        val session = value.filterKeys {
            it?.toString() !in setOf("audioItems", "videoItems", "playlists")
        }
        val library = value.filterKeys { it?.toString() in libraryKeys }
        val playlists = value.filterKeys { it?.toString() in playlistKeys }
        val storage = appStateStorage()
        storage.encode(partitionKey("session"), JSONObject(session).toString())
        storage.encode(partitionKey("library"), JSONObject(library).toString())
        storage.encode(partitionKey("playlists"), JSONObject(playlists).toString())
    }

    private fun backupDirectory(): File {
        val documents = getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS) ?: filesDir
        return File(documents, "忆光/backups").apply { mkdirs() }
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
