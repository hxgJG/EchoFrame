package com.hxg.lumio

import android.app.Activity
import android.content.Intent
import android.os.StatFs
import com.tencent.mmkv.MMKV
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import org.json.JSONObject

class LumioPortableBackupPlugin(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "lumio/portable_backup")
    private val worker = Executors.newSingleThreadExecutor()
    private val root get() = File(activity.cacheDir, "portable_backup").apply { mkdirs() }.canonicalFile
    private var pending: MethodChannel.Result? = null
    private var exportFile: File? = null

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                when (call.method) {
                    "loadWebDavConfiguration", "saveWebDavConfiguration" -> {
                        worker.execute {
                            try {
                                val file = File(activity.noBackupFilesDir, "webdav-backup.json")
                                if (call.method == "saveWebDavConfiguration") {
                                    val config = args["configuration"] as? Map<*, *>
                                    if (config == null) { android.util.AtomicFile(file).delete() }
                                    else {
                                        val json = JSONObject(config).toString()
                                        check(json.length <= 16384) { "云备份配置过长。" }
                                        android.util.AtomicFile(file).let { atomic ->
                                            val output = atomic.startWrite()
                                            try { output.write(json.toByteArray(Charsets.UTF_8)); atomic.finishWrite(output) }
                                            catch (e: Exception) { atomic.failWrite(output); throw e }
                                        }
                                    }
                                    activity.runOnUiThread { result.success(null) }
                                } else {
                                    check(!file.exists() || file.length() <= 16384) { "云备份配置过长。" }
                                    val json = if (file.isFile) JSONObject(String(android.util.AtomicFile(file).readFully(), Charsets.UTF_8)).let { value ->
                                        value.keys().asSequence().associateWith { value.get(it) }
                                    } else null
                                    activity.runOnUiThread { result.success(json) }
                                }
                            } catch (e: Exception) { activity.runOnUiThread { result.error("webdavConfiguration", "无法读写本机云备份配置。", null) } }
                        }
                    }
                    "environment" -> result.success(mapOf(
                        "temporaryRoot" to root.path,
                        "managedRoots" to listOf(activity.filesDir.canonicalPath, activity.cacheDir.canonicalPath, activity.noBackupFilesDir.canonicalPath),
                        "receivedRoot" to File(TransferStoragePaths.root(activity.noBackupFilesDir), "received").canonicalPath,
                        "availableBytes" to StatFs(root.path).availableBytes,
                    ))
                    "export", "import" -> {
                        check(pending == null) { "已有文件选择操作，请先完成。" }
                        val exporting = call.method == "export"
                        val file = if (exporting) File(args["path"] as String).canonicalFile else null
                        if (file != null) check(file.path.startsWith(root.path + "/") && file.isFile) { "备份临时文件无效。" }
                        val intent = Intent(if (exporting) Intent.ACTION_CREATE_DOCUMENT else Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = if (exporting) "application/zip" else "*/*"
                            if (exporting) putExtra(Intent.EXTRA_TITLE, args["name"] as String)
                        }
                        pending = result
                        exportFile = file
                        try { activity.startActivityForResult(intent, if (exporting) EXPORT else IMPORT) }
                        catch (e: Exception) { pending = null; exportFile = null; throw e }
                    }
                    "commit" -> {
                        val state = args["state"] as Map<*, *>
                        worker.execute {
                            try {
                                val keys = setOf("audioItems", "videoItems", "receivedMedia", "lyricLibrary", "lyricLibraryUndo", "playlists", "subtitleProjects")
                                val partitions = mapOf(
                                    "library" to state.filterKeys { it in keys && it != "playlists" && it != "subtitleProjects" || it == "schemaVersion" },
                                    "playlists" to state.filterKeys { it == "playlists" || it == "schemaVersion" },
                                    "session" to state.filterKeys { it !in keys || it == "subtitleProjects" },
                                ).mapValues { JSONObject(it.value).toString() }
                                val storage = MMKV.defaultMMKV()
                                val previous = JSONObject()
                                for (name in partitions.keys) previous.put(name, storage.decodeString("state_$name") ?: JSONObject.NULL)
                                check(storage.encode(JOURNAL, previous.toString())) { "无法保存恢复日志。" }
                                storage.sync()
                                try {
                                    for ((name, json) in partitions) check(storage.encode("state_$name", json)) { "应用数据写入失败。" }
                                    storage.sync()
                                    storage.removeValueForKey(JOURNAL)
                                    storage.sync()
                                } catch (e: Exception) { recover(storage); throw e }
                                activity.runOnUiThread { result.success(null) }
                            } catch (e: Exception) { activity.runOnUiThread { result.error("backupCommit", e.message, null) } }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("portableBackup", e.message, null) }
        }
    }

    fun onActivityResult(code: Int, status: Int, intent: Intent?): Boolean {
        if (code != EXPORT && code != IMPORT) return false
        val result = pending ?: return true
        pending = null
        val source = exportFile
        exportFile = null
        val uri = intent?.data
        if (status != Activity.RESULT_OK || uri == null) { result.success(null); return true }
        worker.execute {
            var directory: File? = null
            try {
                val answer: String
                if (code == EXPORT) {
                    activity.contentResolver.openOutputStream(uri, "wt")?.use { output ->
                        source!!.inputStream().use { it.copyTo(output, 65536) }
                    } ?: error("无法写入所选备份位置。")
                    answer = uri.toString()
                } else {
                    directory = File(root, "import-${UUID.randomUUID()}").apply { check(mkdir()) }
                    val file = File(directory, "backup.zip")
                    activity.contentResolver.openInputStream(uri)?.use { input ->
                        file.outputStream().use { output ->
                            val buffer = ByteArray(65536)
                            var total = 0L
                            while (true) {
                                val read = input.read(buffer)
                                if (read < 0) break
                                total += read
                                check(total <= LIMIT) { "备份超过 2 GiB。" }
                                check(StatFs(root.path).availableBytes > read + 16L * 1024 * 1024) { "备份临时空间不足。" }
                                output.write(buffer, 0, read)
                            }
                        }
                    } ?: error("无法读取所选备份。")
                    answer = file.path
                }
                activity.runOnUiThread { result.success(answer) }
            } catch (e: Exception) {
                directory?.deleteRecursively()
                activity.runOnUiThread { result.error("portableBackup", e.message, null) }
            }
        }
        return true
    }

    fun close() {
        channel.setMethodCallHandler(null)
        pending?.success(null)
        pending = null
        worker.shutdown()
    }

    companion object {
        private const val EXPORT = 2470
        private const val IMPORT = 2471
        private const val LIMIT = 2L * 1024 * 1024 * 1024
        private const val JOURNAL = "portable_backup_rollback_v1"
        fun recover(storage: MMKV) {
            val raw = storage.decodeString(JOURNAL) ?: return
            val previous = JSONObject(raw)
            for (name in listOf("library", "session", "playlists")) {
                if (previous.isNull(name)) storage.removeValueForKey("state_$name")
                else check(storage.encode("state_$name", previous.getString(name))) { "备份恢复回滚失败。" }
            }
            storage.sync()
            storage.removeValueForKey(JOURNAL)
            storage.sync()
        }
    }
}
