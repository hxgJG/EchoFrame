package com.hxg.lumio

import java.io.File
import java.io.IOException

internal object TransferStoragePaths {
    fun root(noBackupFilesDir: File): File {
        // Android may expose its private directory through a system-owned alias.
        // Resolve only that trusted base; app-owned children must not redirect.
        val root = File(noBackupFilesDir.canonicalFile, "lumio_transfer")
        require(root.canonicalFile == root) { "接收目录异常。" }
        if (!root.isDirectory && !root.mkdir()) {
            throw IOException("无法创建接收文件目录。")
        }
        require(root.canonicalFile == root) { "接收目录异常。" }
        return root
    }

    fun lockFile(noBackupFilesDir: File): File {
        val root = root(noBackupFilesDir)
        val file = File(root, ".owner")
        val children = root.list() ?: throw IOException("无法读取接收文件目录。")
        require(file.canonicalFile == file && (file.name !in children || file.isFile)) {
            "接收目录异常。"
        }
        return file
    }
}
