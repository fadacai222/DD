package org.openimx.client

import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dd/media_export")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveImageToGallery" -> saveImageToGallery(call, result)
                    "saveRemoteVideoToGallery" -> saveRemoteVideoToGallery(call, result)
                    "saveRemoteFileToDownloads" -> saveRemoteFileToDownloads(call, result)
                    "openRemoteFile" -> openRemoteFile(call, result)
                    "shareRemoteFile" -> shareRemoteFile(call, result)
                    "copyRemoteFileToClipboard" -> copyRemoteFileToClipboard(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun saveImageToGallery(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error(
                "MEDIASTORE_UNSUPPORTED",
                "Android 10 以下版本暂不支持无存储权限保存到系统相册。",
                null,
            )
            return
        }
        val bytes = call.argument<ByteArray>("bytes")
        val mimeType = call.argument<String>("mimeType") ?: "image/jpeg"
        val fileName = safeFileName(call.argument<String>("fileName") ?: "DD-image.jpg")
        if (bytes == null || bytes.isEmpty()) {
            result.error("INVALID_IMAGE", "图片内容为空。", null)
            return
        }
        try {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
                put(MediaStore.Images.Media.MIME_TYPE, mimeType)
                put(
                    MediaStore.Images.Media.RELATIVE_PATH,
                    Environment.DIRECTORY_PICTURES + "/DD",
                )
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                values,
            ) ?: throw IllegalStateException("无法创建相册媒体记录")
            try {
                contentResolver.openOutputStream(uri, "w").use { stream ->
                    requireNotNull(stream) { "无法打开相册写入流" }
                    stream.write(bytes)
                    stream.flush()
                }
                val completed = ContentValues().apply {
                    put(MediaStore.Images.Media.IS_PENDING, 0)
                }
                contentResolver.update(uri, completed, null, null)
                result.success(uri.toString())
            } catch (error: Throwable) {
                contentResolver.delete(uri, null, null)
                throw error
            }
        } catch (error: Throwable) {
            result.error("MEDIA_EXPORT_FAILED", error.message ?: "图片保存失败", null)
        }
    }

    private fun saveRemoteVideoToGallery(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error(
                "MEDIASTORE_UNSUPPORTED",
                "Android 10 以下版本暂不支持无存储权限保存视频到相册。",
                null,
            )
            return
        }
        val rawUrl = call.argument<String>("url")
        val mimeType = call.argument<String>("mimeType") ?: "video/mp4"
        val fileName = safeFileName(call.argument<String>("fileName") ?: "DD-video.mp4")
        if (rawUrl.isNullOrBlank()) {
            result.error("INVALID_URL", "视频下载地址为空。", null)
            return
        }
        Thread {
            try {
                val values = ContentValues().apply {
                    put(MediaStore.Video.Media.DISPLAY_NAME, fileName)
                    put(MediaStore.Video.Media.MIME_TYPE, mimeType)
                    put(
                        MediaStore.Video.Media.RELATIVE_PATH,
                        Environment.DIRECTORY_MOVIES + "/DD",
                    )
                    put(MediaStore.Video.Media.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(
                    MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                    values,
                ) ?: throw IllegalStateException("无法创建视频相册记录")
                try {
                    contentResolver.openOutputStream(uri, "w").use { output ->
                        requireNotNull(output) { "无法打开视频相册写入流" }
                        openRemoteStream(rawUrl).use { input ->
                            input.copyTo(output, DEFAULT_BUFFER_SIZE)
                        }
                        output.flush()
                    }
                    val completed = ContentValues().apply {
                        put(MediaStore.Video.Media.IS_PENDING, 0)
                    }
                    contentResolver.update(uri, completed, null, null)
                    runOnUiThread { result.success(uri.toString()) }
                } catch (error: Throwable) {
                    contentResolver.delete(uri, null, null)
                    throw error
                }
            } catch (error: Throwable) {
                runOnUiThread {
                    result.error(
                        "MEDIA_EXPORT_FAILED",
                        error.message ?: "视频保存失败",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun saveRemoteFileToDownloads(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error(
                "MEDIASTORE_UNSUPPORTED",
                "Android 10 以下版本请使用系统文件选择器保存文件。",
                null,
            )
            return
        }
        val rawUrl = call.argument<String>("url")
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
        val fileName = safeFileName(call.argument<String>("fileName") ?: "DD-file.bin")
        if (rawUrl.isNullOrBlank()) {
            result.error("INVALID_URL", "文件下载地址为空。", null)
            return
        }
        Thread {
            try {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                    put(MediaStore.Downloads.MIME_TYPE, mimeType)
                    put(
                        MediaStore.Downloads.RELATIVE_PATH,
                        Environment.DIRECTORY_DOWNLOADS + "/DD",
                    )
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    values,
                ) ?: throw IllegalStateException("无法创建下载文件记录")
                try {
                    contentResolver.openOutputStream(uri, "w").use { output ->
                        requireNotNull(output) { "无法打开下载目录写入流" }
                        openRemoteStream(rawUrl).use { input ->
                            input.copyTo(output, DEFAULT_BUFFER_SIZE)
                        }
                        output.flush()
                    }
                    val completed = ContentValues().apply {
                        put(MediaStore.Downloads.IS_PENDING, 0)
                    }
                    contentResolver.update(uri, completed, null, null)
                    runOnUiThread { result.success(uri.toString()) }
                } catch (error: Throwable) {
                    contentResolver.delete(uri, null, null)
                    throw error
                }
            } catch (error: Throwable) {
                runOnUiThread {
                    result.error(
                        "MEDIA_EXPORT_FAILED",
                        error.message ?: "文件保存失败",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun openRemoteFile(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        prepareRemoteFile(call, result, "MEDIA_OPEN_FAILED") { uri, mimeType ->
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            if (intent.resolveActivity(packageManager) == null) {
                throw IllegalStateException("没有可打开此文件类型的应用")
            }
            startActivity(intent)
            true
        }
    }

    private fun shareRemoteFile(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        prepareRemoteFile(call, result, "MEDIA_SHARE_FAILED") { uri, mimeType ->
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = ClipData.newUri(contentResolver, "DD file", uri)
            }
            startActivity(Intent.createChooser(intent, "分享文件"))
            true
        }
    }

    private fun prepareRemoteFile(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
        errorCode: String,
        action: (android.net.Uri, String) -> Boolean,
    ) {
        val rawUrl = call.argument<String>("url")
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
        val fileName = safeFileName(call.argument<String>("fileName") ?: "DD-file.bin")
        if (rawUrl.isNullOrBlank()) {
            result.error("INVALID_URL", "文件下载地址为空。", null)
            return
        }
        Thread {
            try {
                val directory = File(cacheDir, "dd_shared_files").apply { mkdirs() }
                cleanupOldClipboardFiles(directory)
                val target = File(directory, fileName)
                openRemoteStream(rawUrl).use { input ->
                    target.outputStream().buffered().use { output -> input.copyTo(output) }
                }
                val uri = FileProvider.getUriForFile(
                    this,
                    "$packageName.fileprovider",
                    target,
                )
                runOnUiThread {
                    try {
                        result.success(action(uri, mimeType))
                    } catch (error: Throwable) {
                        result.error(errorCode, error.message ?: "文件操作失败", null)
                    }
                }
            } catch (error: Throwable) {
                runOnUiThread {
                    result.error(errorCode, error.message ?: "文件操作失败", null)
                }
            }
        }.start()
    }

    private fun copyRemoteFileToClipboard(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val rawUrl = call.argument<String>("url")
        val fileName = safeFileName(call.argument<String>("fileName") ?: "DD-media.bin")
        if (rawUrl.isNullOrBlank()) {
            result.error("INVALID_URL", "媒体下载地址为空。", null)
            return
        }
        Thread {
            try {
                val directory = File(cacheDir, "dd_clipboard").apply { mkdirs() }
                cleanupOldClipboardFiles(directory)
                val target = File(directory, fileName)
                openRemoteStream(rawUrl).use { input ->
                    target.outputStream().buffered().use { output -> input.copyTo(output) }
                }
                val uri = FileProvider.getUriForFile(
                    this,
                    "$packageName.fileprovider",
                    target,
                )
                val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                val clip = ClipData.newUri(contentResolver, fileName, uri)
                runOnUiThread {
                    clipboard.setPrimaryClip(clip)
                    result.success(true)
                }
            } catch (error: Throwable) {
                runOnUiThread {
                    result.error(
                        "MEDIA_COPY_FAILED",
                        error.message ?: "媒体复制失败",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun openRemoteStream(rawUrl: String): java.io.InputStream {
        val connection = URL(rawUrl).openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = true
        connection.connectTimeout = 15_000
        connection.readTimeout = 60_000
        connection.requestMethod = "GET"
        connection.connect()
        if (connection.responseCode !in 200..299) {
            connection.disconnect()
            throw IllegalStateException("媒体下载失败（HTTP ${connection.responseCode}）")
        }
        return object : java.io.FilterInputStream(connection.inputStream) {
            override fun close() {
                try {
                    super.close()
                } finally {
                    connection.disconnect()
                }
            }
        }
    }

    private fun cleanupOldClipboardFiles(directory: File) {
        val cutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
        directory.listFiles()?.forEach { file ->
            if (file.isFile && file.lastModified() < cutoff) file.delete()
        }
    }

    private fun safeFileName(raw: String): String {
        val forbidden = setOf('<', '>', ':', '"', '/', '\\', '|', '?', '*')
        val value = raw.trim()
            .map { char -> if (char.code < 32 || char in forbidden) '_' else char }
            .joinToString("")
            .trimEnd(' ', '.')
        return if (value.isBlank()) "DD-media" else value.take(120)
    }
}
