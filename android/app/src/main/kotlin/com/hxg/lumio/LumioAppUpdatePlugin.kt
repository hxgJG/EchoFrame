package com.hxg.lumio

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

class LumioAppUpdatePlugin(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "lumio/app_update")
    private val worker = Executors.newSingleThreadExecutor()
    private val root = File(activity.cacheDir, "lumio_updates")
    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method !in listOf("environment", "validate", "open")) {
                result.notImplemented(); return@setMethodCallHandler
            }
            worker.execute {
                try {
                    check(root.exists() || root.mkdirs()) { "无法创建更新缓存目录。" }
                    if (call.method == "environment") {
                        val own = info(activity.packageName)
                        val abi = Build.SUPPORTED_ABIS.firstOrNull() ?: ""
                        val architecture = when (abi) { "arm64-v8a" -> "arm64"; "armeabi-v7a" -> "armv7"; else -> abi }
                        val value = mapOf("platform" to "android", "version" to own.versionName,
                            "buildNumber" to versionCode(own), "osVersion" to Build.VERSION.SDK_INT.toString(),
                            "architecture" to architecture, "cacheRoot" to root.canonicalPath,
                            "availableBytes" to root.usableSpace)
                        activity.runOnUiThread { result.success(value) }
                    } else {
                        val args = call.arguments as? Map<*, *> ?: error("更新参数缺失。")
                        val file = validate(args)
                        activity.runOnUiThread {
                            try {
                                if (call.method == "validate") result.success(null)
                                else if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
                                    activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
                                    result.success("permissionRequired")
                                } else {
                                    val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", file)
                                    val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    intent.clipData = ClipData.newRawUri("Lumio update", uri)
                                    activity.startActivity(intent)
                                    result.success("opened")
                                }
                            } catch (_: Exception) { result.error("update_install", "无法打开系统安装界面，请稍后重试。", null) }
                        }
                    }
                } catch (e: Exception) { activity.runOnUiThread { result.error("update_validation", e.message ?: "更新校验失败。", null) } }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun info(name: String): PackageInfo = activity.packageManager.getPackageInfo(name,
        if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES)
    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    private fun digest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    @Suppress("DEPRECATION")
    private fun signatures(info: PackageInfo): Set<String> =
        (if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures)
            ?.map { digest(it.toByteArray()) }?.toSet() ?: emptySet()

    @Suppress("DEPRECATION")
    private fun validate(args: Map<*, *>): File {
        val path = args["path"] as? String ?: error("更新路径缺失。")
        val file = File(path)
        check(file.canonicalFile == file.absoluteFile && file.parentFile?.canonicalFile == root.canonicalFile &&
            Regex("update-[0-9]+-[0-9]+\\.apk").matches(file.name) && file.isFile) { "更新缓存路径无效。" }
        val size = (args["size"] as? Number)?.toLong() ?: 0
        check(size in 1..1073741824 && file.length() == size) { "更新包长度校验失败。" }
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input -> val buffer = ByteArray(65536); while (true) { val count = input.read(buffer); if (count < 0) break; hash.update(buffer, 0, count) } }
        val actualHash = hash.digest().joinToString("") { "%02x".format(it) }
        check(actualHash == args["sha256"]) { "更新包哈希校验失败。" }
        val archive = activity.packageManager.getPackageArchiveInfo(path,
            if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES)
            ?: error("无法识别此安装包。")
        val installed = info(activity.packageName)
        check(archive.packageName == activity.packageName && archive.versionName == args["version"] &&
            versionCode(archive) == (args["buildNumber"] as? Number)?.toLong() && versionCode(archive) > versionCode(installed)) { "安装包身份或版本不符合更新规则。" }
        check((archive.applicationInfo?.minSdkVersion ?: Int.MAX_VALUE) <= Build.VERSION.SDK_INT) { "系统版本不支持此安装包。" }
        val actual = signatures(archive)
        check(actual.size == 1 && actual == signatures(installed) && actual.single() == args["certificateSha256"]) {
            "签名与当前安装版不一致，不能覆盖更新。请保留现有数据，不要自动卸载。"
        }
        return file
    }
    fun close() { channel.setMethodCallHandler(null); worker.shutdown() }
}
