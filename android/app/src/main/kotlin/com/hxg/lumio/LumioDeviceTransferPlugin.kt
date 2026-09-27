package com.hxg.lumio

import android.app.Activity
import android.content.ContentUris
import android.content.Intent
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.security.KeyStore
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class LumioDeviceTransferPlugin(private val activity: Activity, messenger: BinaryMessenger) {
    private var ownerFile: java.io.RandomAccessFile? = null
    private var ownerLock: java.nio.channels.FileLock? = null
    private data class Lease(val descriptor: ParcelFileDescriptor, val stream: FileInputStream,
        val size: Long, val chunks: List<ByteArray>)
    private val channel = MethodChannel(messenger, "lumio/device_transfer")
    private val worker = Executors.newSingleThreadExecutor()
    private val leases = mutableMapOf<String, Lease>()
    private val blockSize = 256 * 1024
    private val keyAlias = "lumio.transfer.identity.v1"
    private val identityFile get() = File(activity.noBackupFilesDir, "lumio_transfer_identity.v1")
    private var pendingExport: Pair<File, MethodChannel.Result>? = null
    private val exportRequest = 2471

    init {
        channel.setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
            if (call.method == "exportReceived") {
                try {
                    check(pendingExport == null) { "已有文件正在导出。" }
                    val file = privateFile(args["path"] as? String ?: "")
                    val name = (args["name"] as? String ?: "已接收文件").take(100).replace('/', '_')
                    pendingExport = file to result
                    activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/octet-stream"
                        putExtra(Intent.EXTRA_TITLE, "$name.${file.extension}")
                    }, exportRequest)
                } catch (e: Exception) { pendingExport = null; result.error("exportFailed", e.message, null) }
                return@setMethodCallHandler
            }
            worker.execute {
                try {
                    val value: Any? = when (call.method) {
                        "deviceInfo" -> mapOf(
                            "type" to if (activity.resources.configuration.smallestScreenWidthDp >= 600) "平板" else "手机",
                            "brand" to android.os.Build.MANUFACTURER.take(80),
                            "model" to android.os.Build.MODEL.take(80),
                        )
                        "acquireTransferLock" -> { acquireTransferLock(); null }
                        "loadIdentity" -> loadIdentity()
                        "saveIdentity" -> { saveIdentity(args["value"] as String); null }
                        "openMedia" -> openMedia(args)
                        "readMedia" -> readMedia(args["handle"] as String,
                            (args["offset"] as Number).toLong(), (args["length"] as Number).toInt())
                        "closeMedia" -> { closeMedia(args["handle"] as String); null }
                        "closeAll" -> { leases.keys.toList().forEach(::closeMedia); null }
                        else -> { activity.runOnUiThread { result.notImplemented() }; return@execute }
                    }
                    activity.runOnUiThread { result.success(value) }
                } catch (e: Exception) {
                    activity.runOnUiThread { result.error("transferPlatformError", e.message, null) }
                }
            }
        }
    }

    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = store.getKey(keyAlias, null) as? SecretKey
        if (existing != null) return existing
        check(create) { "设备身份密钥无法读取。请勿覆盖原身份。" }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(keyAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }

    private fun acquireTransferLock() {
        if (ownerLock?.isValid == true) return
        val file = TransferStoragePaths.lockFile(activity.noBackupFilesDir)
        val handle = java.io.RandomAccessFile(file, "rw")
        try {
            val lock = handle.channel.tryLock() ?: error("另一个忆光进程正在使用设备互传。")
            ownerFile = handle; ownerLock = lock
        } catch (e: Exception) { handle.close(); throw e }
    }

    private fun loadIdentity(): String? {
        val atomic = AtomicFile(identityFile)
        if (!identityFile.exists() && !File(identityFile.path + ".bak").exists()) return null
        val bytes = atomic.openRead().use { input ->
            val buffer = ByteArray(32769)
            var count = 0
            while (count < buffer.size) {
                val n = input.read(buffer, count, buffer.size - count)
                if (n < 0) break
                count += n
            }
            require(count in 29..32768) { "设备身份数据损坏。" }
            buffer.copyOf(count)
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        return String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8)
    }

    private fun saveIdentity(value: String) {
        require(value.toByteArray().size < 24000 && loadIdentity() == null) { "设备身份已存在或数据无效。" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(true))
        val bytes = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val atomic = AtomicFile(identityFile)
        val stream = atomic.startWrite()
        try { stream.write(bytes); atomic.finishWrite(stream) }
        catch (e: Exception) { atomic.failWrite(stream); throw e }
    }

    private fun privateFile(path: String): File {
        val file = File(path)
        val root = File(activity.noBackupFilesDir, "lumio_transfer/received").canonicalFile
        require(file.absolutePath == file.canonicalPath && file.canonicalFile.parentFile == root && file.isFile) {
            "只能访问 App 已接收目录内的文件。"
        }
        return file
    }

    private fun openMedia(args: Map<*, *>): Map<String, Any> {
        check(leases.size < 4) { "同时打开的传输文件过多，请重试。" }
        val id = args["id"] as? String ?: ""
        val path = args["path"] as? String ?: ""
        val kind = args["kind"] as? String ?: ""
        val descriptor: ParcelFileDescriptor
        val extension: String
        if (id.startsWith("transfer-")) {
            val file = privateFile(path)
            require(file.nameWithoutExtension == id.removePrefix("transfer-"))
            descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            extension = file.extension.lowercase()
        } else {
            val number = id.substringAfterLast('-').toLongOrNull() ?: error("媒体索引无效。")
            require((kind == "audio" || kind == "video") && id.startsWith("android-$kind-"))
            val base = if (kind == "audio") MediaStore.Audio.Media.EXTERNAL_CONTENT_URI else MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            val uri = ContentUris.withAppendedId(base, number)
            extension = activity.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use {
                check(it.moveToFirst()) { "来源文件已移除。" }
                it.getString(0).substringAfterLast('.', "").lowercase()
            } ?: error("媒体不可读取。")
            descriptor = activity.contentResolver.openFileDescriptor(uri, "r") ?: error("媒体不可读取。")
        }
        val input = FileInputStream(descriptor.fileDescriptor)
        try {
            val size = input.channel.size()
            val hash = MessageDigest.getInstance("SHA-256")
            val chunks = mutableListOf<ByteArray>()
            val buffer = ByteArray(blockSize)
            var total = 0L
            while (total < size) {
                check(chunks.size < 262144) { "单个传输文件暂限 64 GiB。" }
                val length = minOf(blockSize.toLong(), size - total).toInt()
                var count = 0
                while (count < length) {
                    val n = input.read(buffer, count, length - count)
                    check(n > 0) { "读取时来源文件发生变化。" }
                    count += n
                }
                hash.update(buffer, 0, count)
                chunks += MessageDigest.getInstance("SHA-256").digest(buffer.copyOf(count))
                total += count
            }
            check(input.channel.size() == size)
            val handle = UUID.randomUUID().toString()
            leases[handle] = Lease(descriptor, input, size, chunks)
            return mapOf("handle" to handle, "size" to size,
                "sha256" to hash.digest().joinToString("") { "%02x".format(it) }, "extension" to extension)
        } catch (e: Exception) { input.close(); descriptor.close(); throw e }
    }

    private fun readMedia(id: String, offset: Long, length: Int): ByteArray {
        val lease = leases[id] ?: error("读取句柄已关闭。")
        require(offset >= 0 && length in 1..blockSize && offset <= lease.size && length <= lease.size - offset)
        val output = ByteArray(length)
        var written = 0
        for (index in (offset / blockSize).toInt()..((offset + length - 1) / blockSize).toInt()) {
            val start = index.toLong() * blockSize
            val count = minOf(blockSize.toLong(), lease.size - start).toInt()
            val buffer = ByteBuffer.allocate(count)
            lease.stream.channel.position(start)
            while (buffer.hasRemaining()) check(lease.stream.channel.read(buffer) > 0) { "来源文件已改变。" }
            val bytes = buffer.array()
            check(MessageDigest.isEqual(MessageDigest.getInstance("SHA-256").digest(bytes), lease.chunks[index])) {
                "来源文件已改变，请重新开启共享。"
            }
            val from = maxOf(0L, offset - start).toInt()
            val to = minOf(count.toLong(), offset + length - start).toInt()
            bytes.copyInto(output, written, from, to)
            written += to - from
        }
        return output
    }

    private fun closeMedia(id: String) {
        val lease = leases.remove(id) ?: return
        try { lease.stream.close() } finally { lease.descriptor.close() }
    }

    fun onActivityResult(request: Int, resultCode: Int, data: Intent?): Boolean {
        if (request != exportRequest) return false
        val pending = pendingExport ?: return true
        pendingExport = null
        val uri: Uri? = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { pending.second.success(false); return true }
        worker.execute {
            try {
                privateFile(pending.first.path).inputStream().use { input ->
                    (activity.contentResolver.openOutputStream(uri, "wt") ?: error("无法写入导出位置。")).use { output ->
                        input.copyTo(output, blockSize)
                    }
                }
                activity.runOnUiThread { pending.second.success(true) }
            } catch (e: Exception) { activity.runOnUiThread { pending.second.error("exportFailed", e.message, null) } }
        }
        return true
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        worker.execute {
            leases.keys.toList().forEach(::closeMedia)
            ownerLock?.release(); ownerFile?.close()
        }
        worker.shutdown()
    }
}
