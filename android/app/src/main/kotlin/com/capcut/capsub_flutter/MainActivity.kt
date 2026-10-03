package com.capcut.capsub_flutter

import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.capcut.capsub/media"
    private val FOREGROUND_CHANNEL = "com.capcut.capsub/foreground_service"
    private val PIP_CHANNEL = "com.capcut.capsub/pip"
    private val mediaExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingMediaPickResult: MethodChannel.Result? = null
    private var pipMethodChannel: MethodChannel? = null

    companion object {
        private const val REQUEST_PICK_MEDIA = 42017
        private const val ACTION_PIP_PLAY_PAUSE = "com.capcut.capsub.PIP_PLAY_PAUSE"
        private const val ACTION_PIP_REWIND = "com.capcut.capsub.PIP_REWIND"
        private const val ACTION_PIP_FORWARD = "com.capcut.capsub.PIP_FORWARD"
        private const val REQUEST_CODE_PLAY_PAUSE = 101
        private const val REQUEST_CODE_REWIND = 102
        private const val REQUEST_CODE_FORWARD = 103
    }

    private var currentPipWidth = 16
    private var currentPipHeight = 9
    private var isPipPlaying = true
    private var isPipReceiverRegistered = false

    private val pipReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                ACTION_PIP_PLAY_PAUSE -> pipMethodChannel?.invokeMethod("onPipAction", "playPause")
                ACTION_PIP_REWIND -> pipMethodChannel?.invokeMethod("onPipAction", "rewind")
                ACTION_PIP_FORWARD -> pipMethodChannel?.invokeMethod("onPipAction", "forward")
            }
        }
    }

    private fun registerPipReceiverIfNeeded() {
        if (!isPipReceiverRegistered) {
            val filter = IntentFilter().apply {
                addAction(ACTION_PIP_PLAY_PAUSE)
                addAction(ACTION_PIP_REWIND)
                addAction(ACTION_PIP_FORWARD)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(pipReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(pipReceiver, filter)
            }
            isPipReceiverRegistered = true
        }
    }

    private fun buildPipParams(width: Int, height: Int, isPlaying: Boolean): PictureInPictureParams? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        val rational = calculateValidPipAspectRatio(width, height)
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(rational)

        // Actions chuẩn đa phương tiện như YouTube: Lùi 10s, Phát/Tạm dừng, Tiến 10s
        val actions = mutableListOf<RemoteAction>()

        // 1. Lùi 10 giây
        val rewPendingIntent = PendingIntent.getBroadcast(
            this,
            REQUEST_CODE_REWIND,
            Intent(ACTION_PIP_REWIND).setPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        actions.add(
            RemoteAction(
                Icon.createWithResource(this, android.R.drawable.ic_media_rew),
                "Lùi 10s",
                "Lùi 10 giây",
                rewPendingIntent
            )
        )

        // 2. Phát / Tạm dừng
        val playPauseIconRes = if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
        val playPauseTitle = if (isPlaying) "Tạm dừng" else "Phát"
        val playPausePendingIntent = PendingIntent.getBroadcast(
            this,
            REQUEST_CODE_PLAY_PAUSE,
            Intent(ACTION_PIP_PLAY_PAUSE).setPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        actions.add(
            RemoteAction(
                Icon.createWithResource(this, playPauseIconRes),
                playPauseTitle,
                playPauseTitle,
                playPausePendingIntent
            )
        )

        // 3. Tiến 10 giây
        val ffPendingIntent = PendingIntent.getBroadcast(
            this,
            REQUEST_CODE_FORWARD,
            Intent(ACTION_PIP_FORWARD).setPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        actions.add(
            RemoteAction(
                Icon.createWithResource(this, android.R.drawable.ic_media_ff),
                "Tiến 10s",
                "Tiến 10 giây",
                ffPendingIntent
            )
        )

        builder.setActions(actions)

        // Android 12+ (API 31+) mượt mà như YouTube: điều chỉnh kích thước mượt mà không nháy đen
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setSeamlessResizeEnabled(true)
            builder.setAutoEnterEnabled(true)
        }

        return builder.build()
    }

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

        pipMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PIP_CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "enterPip" -> {
                        val width = call.argument<Int>("width") ?: 16
                        val height = call.argument<Int>("height") ?: 9
                        val isPlaying = call.argument<Boolean>("isPlaying") ?: true
                        currentPipWidth = width
                        currentPipHeight = height
                        isPipPlaying = isPlaying
                        registerPipReceiverIfNeeded()
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            try {
                                val params = buildPipParams(width, height, isPlaying)
                                val entered = if (params != null) enterPictureInPictureMode(params) else false
                                result.success(entered)
                            } catch (e: Exception) {
                                result.error("PIP_ERROR", e.message, null)
                            }
                        } else {
                            result.error("PIP_UNSUPPORTED", "Picture-in-Picture yêu cầu Android 8.0 trở lên", null)
                        }
                    }
                    "updatePipActions" -> {
                        val isPlaying = call.argument<Boolean>("isPlaying") ?: isPipPlaying
                        isPipPlaying = isPlaying
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            try {
                                val params = buildPipParams(currentPipWidth, currentPipHeight, isPlaying)
                                if (params != null) {
                                    setPictureInPictureParams(params)
                                }
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("UPDATE_PIP_ERROR", e.message, null)
                            }
                        } else {
                            result.success(false)
                        }
                    }
                    "updatePipAspectRatio" -> {
                        val width = call.argument<Int>("width") ?: currentPipWidth
                        val height = call.argument<Int>("height") ?: currentPipHeight
                        currentPipWidth = width
                        currentPipHeight = height
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            try {
                                val params = buildPipParams(width, height, isPipPlaying)
                                if (params != null) {
                                    setPictureInPictureParams(params)
                                }
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("UPDATE_PIP_ERROR", e.message, null)
                            }
                        } else {
                            result.success(false)
                        }
                    }
                    "isPipSupported" -> {
                        val supported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                                packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE)
                        result.success(supported)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }



    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: android.content.res.Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipMethodChannel?.invokeMethod("onPipModeChanged", isInPictureInPictureMode)
    }

    private fun calculateValidPipAspectRatio(width: Int, height: Int): Rational {
        val w = if (width <= 0) 16 else width
        val h = if (height <= 0) 9 else height
        val ratio = w.toFloat() / h.toFloat()
        return when {
            ratio > 2.38f -> Rational(238, 100)
            ratio < 0.42f -> Rational(42, 100)
            else -> Rational(w, h)
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
        if (isPipReceiverRegistered) {
            try {
                unregisterReceiver(pipReceiver)
            } catch (_: Exception) {}
            isPipReceiverRegistered = false
        }
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
}
