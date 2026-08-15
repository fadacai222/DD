package org.openimx.client

import android.Manifest
import android.app.Activity
import android.app.PictureInPictureParams
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Rational
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

class MainActivity : FlutterActivity() {
    companion object {
        private const val CAMERA_PERMISSION_REQUEST = 43101
        private const val CAMERA_CAPTURE_REQUEST = 43102
        private const val FILE_PICKER_REQUEST = 43103
        private const val PHOTO_PICKER_MAX_FILES = 30
        private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
    }

    private var pendingCameraResult: MethodChannel.Result? = null
    private var pendingCameraFile: File? = null
    private var pendingFilePickerResult: MethodChannel.Result? = null
    private var pendingFilePickerMaxFiles = 1
    private var pendingFilePickerMaxBytes: Long? = null

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
                    "saveLocalFileToDownloads" -> saveLocalFileToDownloads(call, result)
                    "openLocalFile" -> openLocalFile(call, result)
                    "shareLocalFile" -> shareLocalFile(call, result)
                    "copyRemoteFileToClipboard" -> copyRemoteFileToClipboard(call, result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dd/camera_capture")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capturePhoto" -> capturePhoto(result)
                    "openAppSettings" -> {
                        openAppSettings()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dd/video_media_probe")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "probeVideo" -> probeVideo(call, result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dd/file_picker")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openFiles" -> openFilesWithoutMaterializingBytes(call, result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dd/external_url")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> openExternalHttpUrl(call, result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dd/picture_in_picture")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(isPictureInPictureSupported())
                    "enter" -> {
                        if (!isPictureInPictureSupported()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val width = (call.argument<Int>("width") ?: 16).coerceAtLeast(1)
                        val height = (call.argument<Int>("height") ?: 9).coerceAtLeast(1)
                        try {
                            val params = PictureInPictureParams.Builder()
                                .setAspectRatio(Rational(width, height))
                                .build()
                            result.success(enterPictureInPictureMode(params))
                        } catch (error: Throwable) {
                            result.error(
                                "PIP_FAILED",
                                error.message ?: "进入画中画失败。",
                                null,
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun probeVideo(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")?.trim()
        if (path.isNullOrEmpty()) {
            result.error("VIDEO_PROBE_INVALID_PATH", "无法读取所选视频的本地路径。", null)
            return
        }
        Thread {
            val retriever = MediaMetadataRetriever()
            var frame: Bitmap? = null
            try {
                if (path.startsWith("content://", ignoreCase = true)) {
                    retriever.setDataSource(this, Uri.parse(path))
                } else {
                    retriever.setDataSource(path)
                }
                val durationMs = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_DURATION,
                )?.toLongOrNull()?.coerceAtLeast(1L)
                    ?: throw IllegalArgumentException("无法读取视频时长。")
                val sourceWidth = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH,
                )?.toIntOrNull()?.coerceAtLeast(1)
                    ?: throw IllegalArgumentException("无法读取视频宽度。")
                val sourceHeight = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT,
                )?.toIntOrNull()?.coerceAtLeast(1)
                    ?: throw IllegalArgumentException("无法读取视频高度。")
                val rotation = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION,
                )?.toIntOrNull() ?: 0

                val maxEdge = maxOf(sourceWidth, sourceHeight)
                val scale = if (maxEdge > 720) 720.0 / maxEdge else 1.0
                val targetWidth = (sourceWidth * scale).toInt().coerceAtLeast(1)
                val targetHeight = (sourceHeight * scale).toInt().coerceAtLeast(1)
                val durationUs = durationMs * 1000L
                val frameTimeUs = (durationUs * 12L / 100L).coerceIn(0L, (durationUs - 1L).coerceAtLeast(0L))

                frame = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    retriever.getScaledFrameAtTime(
                        frameTimeUs,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                        targetWidth,
                        targetHeight,
                    ) ?: retriever.getScaledFrameAtTime(
                        0L,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                        targetWidth,
                        targetHeight,
                    )
                } else {
                    // Android 8.0 and older cannot request a scaled frame. Refuse
                    // very large decoded surfaces instead of risking a process OOM.
                    val pixels = sourceWidth.toLong() * sourceHeight.toLong()
                    if (pixels > 6_000_000L) {
                        throw IllegalArgumentException("当前 Android 版本无法安全生成超高清视频缩略图，请升级系统后重试。")
                    }
                    val raw = retriever.getFrameAtTime(
                        frameTimeUs,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                    ) ?: retriever.getFrameAtTime(0L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    if (raw == null) {
                        null
                    } else if (raw.width == targetWidth && raw.height == targetHeight) {
                        raw
                    } else {
                        Bitmap.createScaledBitmap(raw, targetWidth, targetHeight, true).also {
                            raw.recycle()
                        }
                    }
                }
                val poster = frame ?: throw IllegalArgumentException("视频可以读取，但没有可用缩略图画面。")
                val bytes = ByteArrayOutputStream().use { output ->
                    if (!poster.compress(Bitmap.CompressFormat.JPEG, 82, output)) {
                        throw IllegalStateException("视频缩略图压缩失败。")
                    }
                    output.toByteArray()
                }
                if (bytes.isEmpty()) throw IllegalStateException("视频缩略图为空。")
                val rotated = rotation % 180 != 0
                val displayWidth = if (rotated) sourceHeight else sourceWidth
                val displayHeight = if (rotated) sourceWidth else sourceHeight
                runOnUiThread {
                    result.success(
                        mapOf(
                            "width" to displayWidth,
                            "height" to displayHeight,
                            "durationMs" to durationMs.coerceAtMost(24L * 60L * 60L * 1000L).toInt(),
                            "posterJpeg" to bytes,
                        ),
                    )
                }
            } catch (error: Throwable) {
                runOnUiThread {
                    result.error(
                        "VIDEO_PROBE_FAILED",
                        error.message ?: "Android 无法读取该视频。",
                        null,
                    )
                }
            } finally {
                frame?.recycle()
                try {
                    retriever.release()
                } catch (_: Throwable) {
                }
            }
        }.start()
    }

    private fun isPictureInPictureSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun capturePhoto(result: MethodChannel.Result) {
        if (pendingCameraResult != null) {
            result.error("CAMERA_BUSY", "相机正在使用中。", null)
            return
        }
        pendingCameraResult = result
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            launchCameraCapture()
            return
        }
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.CAMERA),
            CAMERA_PERMISSION_REQUEST,
        )
    }

    private fun launchCameraCapture() {
        val result = pendingCameraResult ?: return
        try {
            val directory = File(cacheDir, "dd_camera").apply { mkdirs() }
            directory.listFiles()?.forEach { old ->
                if (old.isFile && System.currentTimeMillis() - old.lastModified() > 24 * 60 * 60 * 1000L) {
                    old.delete()
                }
            }
            val file = File(directory, "capture-${System.currentTimeMillis()}.jpg")
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
                putExtra(MediaStore.EXTRA_OUTPUT, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                clipData = ClipData.newRawUri("DD camera", uri)
            }
            if (intent.resolveActivity(packageManager) == null) {
                pendingCameraResult = null
                result.error("CAMERA_UNAVAILABLE", "没有可用的系统相机应用。", null)
                return
            }
            pendingCameraFile = file
            startActivityForResult(intent, CAMERA_CAPTURE_REQUEST)
        } catch (error: Throwable) {
            pendingCameraResult = null
            pendingCameraFile?.delete()
            pendingCameraFile = null
            result.error("CAMERA_CAPTURE_FAILED", error.message ?: "启动相机失败。", null)
        }
    }

    private fun openFilesWithoutMaterializingBytes(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        if (pendingFilePickerResult != null) {
            result.error("FILE_PICKER_BUSY", "文件选择器正在使用中。", null)
            return
        }
        val allowMultiple = call.argument<Boolean>("allowMultiple") ?: false
        val requestedMaxFiles = (call.argument<Number>("maxFiles")?.toInt() ?: if (allowMultiple) 30 else 1)
            .coerceIn(1, 100)
        val requestedMaxBytes = call.argument<Number>("maxBytes")?.toLong()?.takeIf { it > 0L }
        val mimeTypes = call.argument<List<String>>("mimeTypes")
            ?.map { it.trim().lowercase() }
            ?.filter { it.isNotEmpty() }
            ?.distinct()
            .orEmpty()
        val source = call.argument<String>("source")?.trim()?.lowercase() ?: "files"

        pendingFilePickerResult = result
        pendingFilePickerMaxFiles = requestedMaxFiles
        pendingFilePickerMaxBytes = requestedMaxBytes
        try {
            if (source == "photos") {
                val wantsImages = mimeTypes.isEmpty() || mimeTypes.any { it.startsWith("image/") }
                val wantsVideos = mimeTypes.isEmpty() || mimeTypes.any { it.startsWith("video/") }
                val mediaType = when {
                    wantsImages && wantsVideos -> ActivityResultContracts.PickVisualMedia.ImageAndVideo
                    wantsVideos -> ActivityResultContracts.PickVisualMedia.VideoOnly
                    else -> ActivityResultContracts.PickVisualMedia.ImageOnly
                }
                val request = PickVisualMediaRequest.Builder()
                    .setMediaType(mediaType)
                    .build()
                val intent = if (allowMultiple) {
                    ActivityResultContracts.PickMultipleVisualMedia(PHOTO_PICKER_MAX_FILES)
                        .createIntent(this, request)
                } else {
                    ActivityResultContracts.PickVisualMedia()
                        .createIntent(this, request)
                }
                startActivityForResult(intent, FILE_PICKER_REQUEST)
            } else {
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = if (mimeTypes.size == 1) mimeTypes.first() else "*/*"
                    if (mimeTypes.size > 1) {
                        putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
                    }
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, allowMultiple)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                startActivityForResult(intent, FILE_PICKER_REQUEST)
            }
        } catch (error: Throwable) {
            pendingFilePickerResult = null
            pendingFilePickerMaxFiles = 1
            pendingFilePickerMaxBytes = null
            result.error("FILE_PICKER_OPEN_FAILED", error.message ?: "无法打开系统文件选择器。", null)
        }
    }

    private fun handleFilePickerResult(resultCode: Int, data: Intent?) {
        if (resultCode != Activity.RESULT_OK || data == null) {
            completePickedUris(emptyList())
            return
        }

        val uris = linkedSetOf<Uri>()
        data.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) {
                clip.getItemAt(index).uri?.let(uris::add)
            }
        }
        data.data?.let(uris::add)
        completePickedUris(uris.toList())
    }

    private fun completePickedUris(rawUris: List<Uri>) {
        val result = pendingFilePickerResult ?: return
        val maxFiles = pendingFilePickerMaxFiles
        val maxBytes = pendingFilePickerMaxBytes
        pendingFilePickerResult = null
        pendingFilePickerMaxFiles = 1
        pendingFilePickerMaxBytes = null

        val uris = rawUris.distinct()
        if (uris.isEmpty()) {
            result.success(emptyList<Map<String, Any?>>())
            return
        }
        if (uris.size > maxFiles) {
            result.error("FILE_PICKER_TOO_MANY", "一次最多选择 $maxFiles 个文件。", null)
            return
        }

        Thread {
            try {
                cleanupPickedFileCache()
                val files = uris.map { uri -> copyPickedFileToCache(uri, maxBytes) }
                runOnUiThread { result.success(files) }
            } catch (error: Throwable) {
                runOnUiThread {
                    result.error(
                        "FILE_PICKER_COPY_FAILED",
                        error.message ?: "读取所选文件失败。",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun copyPickedFileToCache(uri: Uri, maxBytes: Long?): Map<String, Any?> {
        var displayName = "selected-file"
        var declaredSize: Long? = null
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                    displayName = safeFileName(cursor.getString(nameIndex))
                }
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                    declaredSize = cursor.getLong(sizeIndex).coerceAtLeast(0L)
                }
            }
        }
        if (maxBytes != null && declaredSize != null && declaredSize!! > maxBytes) {
            throw IllegalArgumentException("所选文件超过客户端允许的大小。")
        }

        val root = File(cacheDir, "dd_picker").apply { mkdirs() }
        val directory = File(root, UUID.randomUUID().toString()).apply { mkdirs() }
        val target = File(directory, displayName.ifBlank { "selected-file" })
        try {
            val inputStream = contentResolver.openInputStream(uri)
                ?: throw IllegalArgumentException("系统无法读取所选文件。")
            inputStream.buffered(64 * 1024).use { input ->
                target.outputStream().buffered(64 * 1024).use { output ->
                    if (maxBytes == null) {
                        input.copyTo(output, 64 * 1024)
                    } else {
                        val buffer = ByteArray(64 * 1024)
                        var total = 0L
                        while (true) {
                            val read = input.read(buffer)
                            if (read < 0) break
                            total += read.toLong()
                            if (total > maxBytes) {
                                throw IllegalArgumentException("所选文件超过客户端允许的大小。")
                            }
                            output.write(buffer, 0, read)
                        }
                    }
                }
            }
            if (!target.exists() || target.length() <= 0L) {
                throw IllegalArgumentException("所选文件为空或无法读取。")
            }
            return mapOf(
                "path" to target.absolutePath,
                "name" to displayName,
                "mimeType" to contentResolver.getType(uri),
                "size" to target.length(),
            )
        } catch (error: Throwable) {
            target.delete()
            directory.delete()
            throw error
        }
    }

    private fun cleanupPickedFileCache() {
        val root = File(cacheDir, "dd_picker")
        val cutoff = System.currentTimeMillis() - 24L * 60L * 60L * 1000L
        root.listFiles()?.forEach { entry ->
            if (entry.lastModified() < cutoff) entry.deleteRecursively()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != CAMERA_PERMISSION_REQUEST) return
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            launchCameraCapture()
            return
        }
        pendingCameraResult?.error(
            "CAMERA_PERMISSION_DENIED",
            "相机权限被拒绝，请在系统设置中允许 DD 使用相机。",
            null,
        )
        pendingCameraResult = null
        pendingCameraFile?.delete()
        pendingCameraFile = null
    }

    @Deprecated("Deprecated in Android API; retained for external camera app compatibility.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == FILE_PICKER_REQUEST) {
            handleFilePickerResult(resultCode, data)
            return
        }
        if (requestCode != CAMERA_CAPTURE_REQUEST) return
        val result = pendingCameraResult
        val file = pendingCameraFile
        pendingCameraResult = null
        pendingCameraFile = null
        if (result == null) {
            file?.delete()
            return
        }
        if (resultCode != Activity.RESULT_OK) {
            file?.delete()
            result.success(null)
            return
        }
        if (file == null || !file.exists() || file.length() <= 0) {
            file?.delete()
            result.error("CAMERA_CAPTURE_EMPTY", "相机没有返回有效照片。", null)
            return
        }
        result.success(file.absolutePath)
    }

    private fun openExternalHttpUrl(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        val raw = call.argument<String>("url")?.trim().orEmpty()
        val uri = runCatching { Uri.parse(raw) }.getOrNull()
        val scheme = uri?.scheme?.lowercase()
        if (uri == null || (scheme != "http" && scheme != "https") || uri.host.isNullOrBlank()) {
            result.error("INVALID_EXTERNAL_URL", "只允许打开 HTTP/HTTPS 链接。", null)
            return
        }
        try {
            val intent = Intent(Intent.ACTION_VIEW, uri).apply {
                addCategory(Intent.CATEGORY_BROWSABLE)
            }
            startActivity(intent)
            result.success(true)
        } catch (error: Throwable) {
            result.error(
                "EXTERNAL_URL_OPEN_FAILED",
                error.message ?: "无法调用系统浏览器打开链接。",
                null,
            )
        }
    }

    private fun openAppSettings() {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", packageName, null),
        ).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
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

    private fun saveLocalFileToDownloads(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error(
                "MEDIASTORE_UNSUPPORTED",
                "Android 10 以下版本请使用系统文件选择器保存文件。",
                null,
            )
            return
        }
        val path = call.argument<String>("path")
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
        val fileName = safeFileName(call.argument<String>("fileName") ?: "DD-file.bin")
        val source = path?.let(::File)
        if (source == null || !source.isFile) {
            result.error("LOCAL_FILE_MISSING", "本地缓存文件不存在。", null)
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
                        source.inputStream().buffered().use { input -> input.copyTo(output) }
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

    private fun openLocalFile(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val local = localSharedFile(call, result) ?: return
        val requestedMimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
        val fileName = call.argument<String>("fileName")?.trim().orEmpty()
        val isApk = requestedMimeType.equals(APK_MIME_TYPE, ignoreCase = true) ||
            fileName.lowercase().endsWith(".apk")
        val mimeType = if (isApk) APK_MIME_TYPE else requestedMimeType
        try {
            val intent = if (isApk) {
                Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                    data = local
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    clipData = ClipData.newUri(contentResolver, "DD APK", local)
                }
            } else {
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(local, mimeType)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    clipData = ClipData.newUri(contentResolver, "DD file", local)
                }
            }
            if (intent.resolveActivity(packageManager) == null) {
                throw IllegalStateException("没有可打开此文件类型的应用")
            }
            startActivity(intent)
            result.success(true)
        } catch (error: Throwable) {
            result.error("MEDIA_OPEN_FAILED", error.message ?: "文件打开失败", null)
        }
    }

    private fun shareLocalFile(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val local = localSharedFile(call, result) ?: return
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
        try {
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, local)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = ClipData.newUri(contentResolver, "DD file", local)
            }
            startActivity(Intent.createChooser(intent, "分享文件"))
            result.success(true)
        } catch (error: Throwable) {
            result.error("MEDIA_SHARE_FAILED", error.message ?: "文件分享失败", null)
        }
    }

    private fun localSharedFile(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ): android.net.Uri? {
        val path = call.argument<String>("path")
        val source = path?.let(::File)
        if (source == null || !source.isFile) {
            result.error("LOCAL_FILE_MISSING", "本地缓存文件不存在。", null)
            return null
        }
        return try {
            FileProvider.getUriForFile(this, "$packageName.fileprovider", source)
        } catch (error: Throwable) {
            result.error("LOCAL_FILE_SHARE_FAILED", error.message ?: "无法共享本地文件", null)
            null
        }
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
