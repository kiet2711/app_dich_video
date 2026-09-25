package com.capcut.capsub_flutter

import android.app.Activity
import android.content.Intent
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.capcut.capsub/media"
    private val FOREGROUND_CHANNEL = "com.capcut.capsub/foreground_service"
    private val mediaExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingMediaPickResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickMedia" -> {
                    val videoOnly = call.argument<Boolean>("videoOnly") ?: false
                    openPersistentMediaPicker(videoOnly, result)
                }
                "copyContentUri" -> {
                    val uri = call.argument<String>("uri") ?: ""
                    val outputPath = call.argument<String>("outputPath") ?: ""
                    mediaExecutor.execute {
                        try {
                            val bytes = copyContentUri(uri, outputPath)
                            mainHandler.post { result.success(bytes) }
                        } catch (e: Exception) {
                            mainHandler.post { result.error("COPY_URI_FAILED", e.message, null) }
                        }
                    }
                }
                "getContentMetadata" -> {
                    val uri = call.argument<String>("uri") ?: ""
                    mediaExecutor.execute {
                        try {
                            val metadata = getContentMetadata(uri)
                            mainHandler.post { result.success(metadata) }
                        } catch (e: Exception) {
                            mainHandler.post { result.error("CONTENT_METADATA_FAILED", e.message, null) }
                        }
                    }
                }
                "probeMedia" -> {
                    val mediaPath = call.argument<String>("mediaPath") ?: ""
                    mediaExecutor.execute {
                        try {
                            val duration = probeDuration(mediaPath)
                            mainHandler.post { result.success(duration) }
                        } catch (e: Exception) {
                            mainHandler.post { result.error("PROBE_FAILED", e.message, null) }
                        }
                    }
                }
                "extractAudio" -> {
                    val videoPath = call.argument<String>("videoPath") ?: ""
                    val outputPath = call.argument<String>("outputPath") ?: ""
                    val startMs = (call.argument<Number>("startMs")?.toLong()) ?: 0L
                    val durationMs = (call.argument<Number>("durationMs")?.toLong()) ?: -1L

                    mediaExecutor.execute {
                        try {
                            val duration = extractAudioDirect(videoPath, outputPath, startMs, durationMs)
                            mainHandler.post { result.success(duration) }
                        } catch (e: Exception) {
                            mainHandler.post { result.error("EXTRACT_ERROR", e.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FOREGROUND_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val title = call.argument<String>("title") ?: "CapSub AI Studio"
                    val message = call.argument<String>("message") ?: "Đang xử lý..."
                    val progress = call.argument<Int>("progress") ?: 0
                    val maxProgress = call.argument<Int>("maxProgress") ?: 100
                    AppForegroundService.start(applicationContext, title, message, progress, maxProgress)
                    result.success(true)
                }
                "update" -> {
                    val title = call.argument<String>("title")
                    val message = call.argument<String>("message") ?: "Đang xử lý..."
                    val progress = call.argument<Int>("progress") ?: 0
                    val maxProgress = call.argument<Int>("maxProgress") ?: 100
                    AppForegroundService.update(applicationContext, title, message, progress, maxProgress)
                    result.success(true)
                }
                "stop" -> {
                    AppForegroundService.stop(applicationContext)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun openPersistentMediaPicker(videoOnly: Boolean, result: MethodChannel.Result) {
        if (pendingMediaPickResult != null) {
            result.error("PICKER_ACTIVE", "Một trình chọn media khác đang mở", null)
            return
        }
        pendingMediaPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (videoOnly) "video/*" else "*/*"
            if (!videoOnly) {
                putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("video/*", "audio/*"))
            }
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQUEST_PICK_MEDIA)
        } catch (error: Exception) {
            pendingMediaPickResult = null
            result.error("PICKER_FAILED", error.message, null)
        }
    }

    @Deprecated("Deprecated in Android SDK, retained for FlutterActivity picker interop")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PICK_MEDIA) return
        val result = pendingMediaPickResult ?: return
        pendingMediaPickResult = null

        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }

        val uri = data.data!!
        var persisted = false
        try {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
            persisted = true
        } catch (_: Exception) {
            // Một số nhà cung cấp chỉ cấp quyền tạm thời. Dart sẽ sao chép dự phòng.
        }

        try {
            val metadata = queryOpenableMetadata(uri).toMutableMap()
            metadata["uri"] = uri.toString()
            metadata["persisted"] = persisted
            result.success(metadata)
        } catch (error: Exception) {
            result.error("PICKER_RESULT_FAILED", error.message, null)
        }
    }

    override fun onDestroy() {
        AppForegroundService.stop(applicationContext)
        pendingMediaPickResult?.error(
            "ACTIVITY_DESTROYED",
            "Activity đã đóng khi đang chọn media",
            null,
        )
        pendingMediaPickResult = null
        mediaExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun queryOpenableMetadata(uri: Uri): Map<String, Any> {
        var name = uri.lastPathSegment ?: "media"
        var size = -1L
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                    name = cursor.getString(nameIndex)
                }
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                    size = cursor.getLong(sizeIndex)
                }
            }
        }
        return mutableMapOf<String, Any>("name" to name).apply {
            if (size >= 0) this["sizeBytes"] = size
        }
    }

    private fun getContentMetadata(uriText: String): Map<String, Any> {
        require(uriText.startsWith("content://")) { "URI media không hợp lệ" }
        val uri = Uri.parse(uriText)
        return queryOpenableMetadata(uri).toMutableMap().apply {
            this["durationMs"] = probeDuration(uriText)
        }
    }

    private fun copyContentUri(uriText: String, outputPath: String): Long {
        require(uriText.startsWith("content://")) { "URI media không hợp lệ" }
        require(outputPath.isNotBlank()) { "Đường dẫn đầu ra trống" }
        val output = File(outputPath).canonicalFile
        val appDataDir = File(applicationInfo.dataDir).canonicalFile
        require(output.path.startsWith(appDataDir.path + File.separator)) {
            "Chỉ được sao chép media vào vùng dữ liệu ứng dụng"
        }
        output.parentFile?.mkdirs()
        try {
            contentResolver.openInputStream(Uri.parse(uriText)).use { input ->
                requireNotNull(input) { "Không mở được URI media" }
                output.outputStream().use { target -> input.copyTo(target) }
            }
            return output.length()
        } catch (error: Exception) {
            output.delete()
            throw error
        }
    }

    private fun probeDuration(mediaPath: String): Long {
        require(mediaPath.isNotBlank()) { "Đường dẫn media trống" }
        val retriever = MediaMetadataRetriever()
        try {
            if (mediaPath.startsWith("http://") || mediaPath.startsWith("https://")) {
                retriever.setDataSource(mediaPath, networkHeaders(mediaPath))
            } else if (mediaPath.startsWith("content://")) {
                retriever.setDataSource(context, Uri.parse(mediaPath))
            } else {
                retriever.setDataSource(mediaPath)
            }
            return retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
                ?.takeIf { it > 0 }
                ?: error("Không đọc được thời lượng media")
        } finally {
            retriever.release()
        }
    }

    private fun extractAudioDirect(videoPath: String, outputPath: String, startMs: Long, durationMs: Long): Long {
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        try {
            val videoUri = if (videoPath.startsWith("content://") || videoPath.startsWith("http://") || videoPath.startsWith("https://")) {
                Uri.parse(videoPath)
            } else {
                Uri.fromFile(File(videoPath))
            }
            val headers = if (videoPath.startsWith("http://") || videoPath.startsWith("https://")) {
                networkHeaders(videoPath)
            } else null
            extractor.setDataSource(context, videoUri, headers)
            val trackCount = extractor.trackCount
            var audioTrackIndex = -1
            var audioFormat: MediaFormat? = null

            for (i in 0 until trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/")) {
                    audioTrackIndex = i
                    audioFormat = format
                    break
                }
            }

            if (audioTrackIndex == -1 || audioFormat == null) {
                throw IllegalStateException("Không tìm thấy track âm thanh")
            }

            extractor.selectTrack(audioTrackIndex)
            val totalDurationUs = if (audioFormat.containsKey(MediaFormat.KEY_DURATION)) {
                audioFormat.getLong(MediaFormat.KEY_DURATION)
            } else 0L

            val startUs = startMs * 1000L
            val endUs = if (durationMs > 0) startUs + (durationMs * 1000L) else Long.MAX_VALUE

            if (startUs > 0) {
                extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
            }

            val outFile = File(outputPath)
            outFile.parentFile?.mkdirs()
            muxer = MediaMuxer(outFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val outputTrackIndex = muxer.addTrack(audioFormat)
            muxer.start()

            val maxBufferSize = if (audioFormat.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                audioFormat.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE).coerceAtLeast(256 * 1024)
            } else 256 * 1024

            val buffer = ByteBuffer.allocate(maxBufferSize)
            val bufferInfo = MediaCodec.BufferInfo()
            var firstSampleTimeUs = -1L
            var lastSampleTimeUs = -1L

            while (true) {
                buffer.clear()
                bufferInfo.size = extractor.readSampleData(buffer, 0)
                if (bufferInfo.size < 0) break

                val sampleTimeUs = extractor.sampleTime
                if (sampleTimeUs > endUs) break

                if (firstSampleTimeUs < 0) firstSampleTimeUs = sampleTimeUs
                lastSampleTimeUs = sampleTimeUs
                bufferInfo.offset = 0
                bufferInfo.presentationTimeUs = sampleTimeUs - firstSampleTimeUs
                bufferInfo.flags = if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) {
                    MediaCodec.BUFFER_FLAG_KEY_FRAME
                } else 0

                muxer.writeSampleData(outputTrackIndex, buffer, bufferInfo)
                extractor.advance()
            }

            check(firstSampleTimeUs >= 0) { "Track âm thanh không có dữ liệu" }
            return ((lastSampleTimeUs - firstSampleTimeUs).coerceAtLeast(0L)) / 1000
        } finally {
            try { muxer?.stop() } catch (_: Exception) {}
            try { muxer?.release() } catch (_: Exception) {}
            try { extractor.release() } catch (_: Exception) {}
        }
    }

    private fun networkHeaders(url: String): Map<String, String> {
        val lower = url.lowercase()
        return if (lower.contains("bilibili.com") || lower.contains("bilivideo.com") || lower.contains("b23.tv")) {
            mapOf(
                "Referer" to "https://www.bilibili.com/",
                "Origin" to "https://www.bilibili.com",
                "User-Agent" to "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36",
            )
        } else if (lower.contains("hongguoduanju.com") ||
            lower.contains("novelquickapp.com") ||
            lower.contains("qznovelvod.com") ||
            lower.contains("fanqiesc.com") ||
            lower.contains("fqnovel.com") ||
            lower.contains("bytevcloud.com") ||
            lower.contains("snssdk.com") ||
            lower.contains("pstatp.com")
        ) {
            mapOf(
                "Referer" to "https://www.hongguoduanju.com/",
                "Origin" to "https://www.hongguoduanju.com",
                "User-Agent" to "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0.0.0 Safari/537.36",
            )
        } else if (lower.contains("douyin.com") || lower.contains("douyinvod.com") || lower.contains("iesdouyin.com")) {
            mapOf(
                "Referer" to "https://www.douyin.com/",
                "Origin" to "https://www.douyin.com",
                "User-Agent" to "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0.0.0 Safari/537.36",
            )
        } else if (lower.contains("tiktok.com") || lower.contains("tiktokv.com")) {
            mapOf(
                "Referer" to "https://www.tiktok.com/",
                "Origin" to "https://www.tiktok.com",
                "User-Agent" to "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0.0.0 Safari/537.36",
            )
        } else {
            mapOf("User-Agent" to "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
        }
    }

    companion object {
        private const val REQUEST_PICK_MEDIA = 42017
    }
}
