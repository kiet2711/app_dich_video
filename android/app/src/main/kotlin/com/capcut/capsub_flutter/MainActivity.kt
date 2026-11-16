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
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaMetadataRetriever
import android.media.PlaybackParams
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.capcut.capsub/media"
    private val FOREGROUND_CHANNEL = "com.capcut.capsub/foreground_service"
    private val PIP_CHANNEL = "com.capcut.capsub/pip"
    private val LIVE_AUDIO_CHANNEL = "com.capcut.capsub/live_audio"
    private val mediaExecutor = Executors.newSingleThreadExecutor()
    private val pcmExecutor = Executors.newCachedThreadPool()
    private val pcmReaders = ConcurrentHashMap<String, PcmStreamReader>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingMediaPickResult: MethodChannel.Result? = null
    private var pipMethodChannel: MethodChannel? = null
    private var livePcmPlayer: AndroidLivePcmPlayer? = null

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
                            val resultMap = extractAudioDirect(videoPath, outputPath, startMs, durationMs)
                            mainHandler.post { result.success(resultMap) }
                        } catch (e: Exception) {
                            mainHandler.post { result.error("EXTRACT_ERROR", e.message, null) }
                        }
                    }
                }
                "openPcmStream" -> {
                    val mediaPath = call.argument<String>("mediaPath") ?: ""
                    val rawHeaders = call.argument<Map<String, Any?>>("headers") ?: emptyMap()
                    val customHeaders = rawHeaders.mapNotNull { (k, v) ->
                        val valStr = v?.toString()?.trim()
                        if (valStr.isNullOrEmpty()) null else k to valStr
                    }.toMap()
                    val startMs = (call.argument<Number>("startMs")?.toLong()) ?: 0L
                    pcmExecutor.execute {
                        try {
                            val streamId = UUID.randomUUID().toString()
                            val reader = PcmStreamReader(applicationContext)
                            val durationMs = reader.open(
                                mediaPath = mediaPath,
                                passedHeaders = customHeaders,
                                defaultHeadersFn = { url -> networkHeaders(url) },
                                startMs = startMs,
                            )
                            pcmReaders[streamId] = reader
                            mainHandler.post {
                                result.success(
                                    mapOf(
                                        "streamId" to streamId,
                                        "durationMs" to durationMs,
                                    ),
                                )
                            }
                        } catch (e: Exception) {
                            mainHandler.post {
                                result.error("PCM_OPEN_ERROR", e.message ?: "Không mở được luồng âm thanh PCM", null)
                            }
                        }
                    }
                }
                "readPcmChunk" -> {
                    val streamId = call.argument<String>("streamId") ?: ""
                    val durationMs = ((call.argument<Number>("durationMs")?.toInt()) ?: 250).coerceIn(40, 5000)
                    val reader = pcmReaders[streamId]
                    if (reader == null) {
                        result.error("PCM_NOT_FOUND", "Phiên PCM không tồn tại hoặc đã đóng", null)
                        return@setMethodCallHandler
                    }
                    pcmExecutor.execute {
                        try {
                            val chunk = reader.readChunk(durationMs)
                            mainHandler.post { result.success(chunk) }
                        } catch (e: Exception) {
                            mainHandler.post {
                                result.error("PCM_READ_ERROR", e.message ?: "Lỗi đọc PCM", null)
                            }
                        }
                    }
                }
                "seekPcmStream" -> {
                    val streamId = call.argument<String>("streamId") ?: ""
                    val positionMs = (call.argument<Number>("positionMs")?.toLong()) ?: 0L
                    val reader = pcmReaders[streamId]
                    if (reader == null) {
                        result.success(positionMs)
                        return@setMethodCallHandler
                    }
                    pcmExecutor.execute {
                        try {
                            val actualPos = reader.seekTo(positionMs)
                            mainHandler.post { result.success(actualPos) }
                        } catch (e: Exception) {
                            mainHandler.post {
                                result.error("PCM_SEEK_ERROR", e.message ?: "Lỗi tua luồng PCM", null)
                            }
                        }
                    }
                }
                "closePcmStream" -> {
                    val streamId = call.argument<String>("streamId") ?: ""
                    val reader = pcmReaders.remove(streamId)
                    if (reader != null) {
                        pcmExecutor.execute {
                            reader.close()
                        }
                    }
                    result.success(true)
                }
                "moveToBack" -> {
                    moveTaskToBack(true)
                    result.success(true)
                }
                "checkVideoDecoderSupport" -> {
                    val width = call.argument<Int>("width") ?: 1080
                    val height = call.argument<Int>("height") ?: 1920
                    result.success(checkVideoDecoderSupport(width, height))
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

        val liveAudioChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LIVE_AUDIO_CHANNEL)
        livePcmPlayer?.dispose()
        val livePlayer = AndroidLivePcmPlayer(liveAudioChannel, mainHandler)
        livePcmPlayer = livePlayer
        liveAudioChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val sampleRate = call.argument<Number>("sampleRate")?.toInt() ?: 24000
                    val volume = call.argument<Number>("volume")?.toFloat() ?: 1.0f
                    val rate = call.argument<Number>("rate")?.toFloat() ?: 1.0f
                    livePlayer.configure(sampleRate, volume, rate)
                    result.success(true)
                }
                "enqueuePcm" -> {
                    val pcm = call.argument<ByteArray>("pcm")
                    if (pcm == null) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val sampleRate = call.argument<Number>("sampleRate")?.toInt() ?: 24000
                    livePlayer.enqueuePcm(pcm, sampleRate)
                    result.success(true)
                }
                "setVolume" -> {
                    val volume = call.argument<Number>("volume")?.toFloat() ?: 1.0f
                    livePlayer.setVolume(volume)
                    result.success(true)
                }
                "setPlaybackRate" -> {
                    val rate = call.argument<Number>("rate")?.toFloat() ?: 1.0f
                    livePlayer.setPlaybackRate(rate)
                    result.success(true)
                }
                "setPaused" -> {
                    val paused = call.argument<Boolean>("paused") ?: false
                    livePlayer.setPaused(paused)
                    result.success(true)
                }
                "interrupt" -> {
                    livePlayer.interrupt()
                    result.success(true)
                }
                "dispose" -> {
                    livePlayer.dispose()
                    result.success(true)
                }
                else -> result.notImplemented()
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

    private fun checkVideoDecoderSupport(width: Int, height: Int): Map<String, Boolean> {
        var avcSupported = false
        var hevcSupported = false
        try {
            val codecs = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            for (info in codecs) {
                if (info.isEncoder) continue
                for (type in info.supportedTypes) {
                    val lower = type.lowercase()
                    if (lower != "video/avc" && lower != "video/hevc") continue
                    val sizeOk = try {
                        val caps = info.getCapabilitiesForType(type)
                        val vc = caps.videoCapabilities
                        vc == null || vc.isSizeSupported(width, height) || vc.isSizeSupported(height, width)
                    } catch (_: Throwable) {
                        true
                    }
                    if (!sizeOk) continue
                    if (lower == "video/avc") avcSupported = true
                    if (lower == "video/hevc") hevcSupported = true
                }
            }
        } catch (_: Throwable) {
            // Fail-open nếu thiết bị chặn truy vấn MediaCodecList
            return mapOf("avc" to true, "hevc" to true)
        }
        return mapOf("avc" to avcSupported, "hevc" to hevcSupported)
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
        for ((_, reader) in pcmReaders) {
            try {
                reader.close()
            } catch (_: Exception) {}
        }
        pcmReaders.clear()
        livePcmPlayer?.dispose()
        livePcmPlayer = null
        pcmExecutor.shutdownNow()
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

    private fun extractAudioDirect(videoPath: String, outputPath: String, startMs: Long, durationMs: Long): Map<String, Long> {
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
                extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
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

                // Bỏ qua các sample âm thanh nằm trước startUs để tránh thừa âm thanh cũ của chunk trước
                if (sampleTimeUs < startUs) {
                    extractor.advance()
                    continue
                }

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
            val actualStartMs = firstSampleTimeUs / 1000L
            val actualDurationMs = ((lastSampleTimeUs - firstSampleTimeUs).coerceAtLeast(0L)) / 1000L
            return mapOf(
                "actualStartMs" to actualStartMs,
                "durationMs" to actualDurationMs
            )
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

    private class PcmStreamReader(private val appContext: Context) {
        private val lock = Any()
        private var extractor: MediaExtractor? = null
        private var codec: MediaCodec? = null
        private var inputDone = false
        private var outputDone = false
        private var sampleRate = 44100
        private var channelCount = 1
        private var pcmEncoding = AudioFormat.ENCODING_PCM_16BIT
        private var durationMs = 0L

        private var anchorTimeMs = 0L
        private var emitted16kSamples = 0L
        private var seekTargetUs = -1L

        private var hasPrevSample = false
        private var prevMonoSample = 0.0
        private var resamplePhase = 0.0

        private var leftoverPcm = ByteArray(0)
        private var leftoverOffset = 0

        @Volatile
        private var closed = false

        fun open(
            mediaPath: String,
            passedHeaders: Map<String, String>,
            defaultHeadersFn: (String) -> Map<String, String>,
            startMs: Long,
        ): Long = synchronized(lock) {
            require(mediaPath.isNotBlank()) { "Đường dẫn media trống" }
            val ext = MediaExtractor()
            val mediaUri = if (mediaPath.startsWith("content://") ||
                mediaPath.startsWith("http://") ||
                mediaPath.startsWith("https://")
            ) {
                Uri.parse(mediaPath)
            } else {
                Uri.fromFile(File(mediaPath))
            }

            val isHttp = mediaPath.startsWith("http://") || mediaPath.startsWith("https://")
            val mergedHeaders = if (isHttp) {
                val base = defaultHeadersFn(mediaPath).toMutableMap()
                for ((k, v) in passedHeaders) {
                    if (v.isNotBlank()) base[k] = v
                }
                base
            } else null

            ext.setDataSource(appContext, mediaUri, mergedHeaders)

            var audioIndex = -1
            var trackFormat: MediaFormat? = null
            for (i in 0 until ext.trackCount) {
                val fmt = ext.getTrackFormat(i)
                val mime = fmt.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/")) {
                    audioIndex = i
                    trackFormat = fmt
                    break
                }
            }
            if (audioIndex == -1 || trackFormat == null) {
                ext.release()
                throw IllegalStateException("Không tìm thấy track âm thanh trong nguồn này")
            }

            ext.selectTrack(audioIndex)
            durationMs = if (trackFormat.containsKey(MediaFormat.KEY_DURATION)) {
                (trackFormat.getLong(MediaFormat.KEY_DURATION) / 1000L).coerceAtLeast(0L)
            } else {
                0L
            }
            if (trackFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                sampleRate = trackFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE).coerceAtLeast(8000)
            }
            if (trackFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                channelCount = trackFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceAtLeast(1)
            }

            val mime = trackFormat.getString(MediaFormat.KEY_MIME)
                ?: throw IllegalStateException("Thiếu MIME audio")
            val decoder = MediaCodec.createDecoderByType(mime)
            decoder.configure(trackFormat, null, null, 0)
            decoder.start()

            extractor = ext
            codec = decoder

            if (startMs > 0) {
                seekInternal(startMs)
            } else {
                anchorTimeMs = 0L
                emitted16kSamples = 0L
                seekTargetUs = -1L
            }
            return durationMs
        }

        fun seekTo(positionMs: Long): Long = synchronized(lock) {
            if (closed) return positionMs
            return seekInternal(positionMs)
        }

        private fun seekInternal(positionMs: Long): Long {
            val safeMs = positionMs.coerceAtLeast(0L)
            val ext = extractor ?: return safeMs
            val dec = codec ?: return safeMs
            val targetUs = safeMs * 1000L
            try {
                dec.flush()
            } catch (_: Exception) {}
            ext.seekTo(targetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            inputDone = false
            outputDone = false
            hasPrevSample = false
            prevMonoSample = 0.0
            resamplePhase = 0.0
            leftoverPcm = ByteArray(0)
            leftoverOffset = 0
            seekTargetUs = targetUs
            anchorTimeMs = safeMs
            emitted16kSamples = 0L
            return safeMs
        }

        fun readChunk(requestedDurationMs: Int): Map<String, Any> = synchronized(lock) {
            if (closed) {
                return mapOf(
                    "pcm" to ByteArray(0),
                    "startMs" to anchorTimeMs,
                    "endMs" to anchorTimeMs,
                    "eof" to true,
                )
            }
            val ext = extractor
            val dec = codec
            if (ext == null || dec == null) {
                return mapOf(
                    "pcm" to ByteArray(0),
                    "startMs" to anchorTimeMs,
                    "endMs" to anchorTimeMs,
                    "eof" to true,
                )
            }

            val targetSamples = (requestedDurationMs * 16000L / 1000L).toInt().coerceAtLeast(160)
            val targetBytes = targetSamples * 2
            val out = ByteArrayOutputStream(targetBytes)

            val chunkStartMs = anchorTimeMs + (emitted16kSamples * 1000L / 16000L)

            if (leftoverOffset < leftoverPcm.size) {
                val avail = leftoverPcm.size - leftoverOffset
                val take = minOf(avail, targetBytes)
                out.write(leftoverPcm, leftoverOffset, take)
                leftoverOffset += take
                if (leftoverOffset >= leftoverPcm.size) {
                    leftoverPcm = ByteArray(0)
                    leftoverOffset = 0
                }
            }

            val bufferInfo = MediaCodec.BufferInfo()
            val startWallMs = System.currentTimeMillis()

            while (out.size() < targetBytes && !outputDone && !closed) {
                if (System.currentTimeMillis() - startWallMs > 6000L) {
                    break
                }

                if (!inputDone) {
                    val inIdx = dec.dequeueInputBuffer(5_000L)
                    if (inIdx >= 0) {
                        val inBuf = dec.getInputBuffer(inIdx)
                        if (inBuf != null) {
                            inBuf.clear()
                            val sampleSize = ext.readSampleData(inBuf, 0)
                            if (sampleSize < 0) {
                                dec.queueInputBuffer(
                                    inIdx,
                                    0,
                                    0,
                                    0L,
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                                )
                                inputDone = true
                            } else {
                                val ptsUs = ext.sampleTime.coerceAtLeast(0L)
                                dec.queueInputBuffer(inIdx, 0, sampleSize, ptsUs, 0)
                                ext.advance()
                            }
                        }
                    }
                }

                val outIdx = dec.dequeueOutputBuffer(bufferInfo, 5_000L)
                when {
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val fmt = dec.outputFormat
                        if (fmt.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                            sampleRate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE).coerceAtLeast(8000)
                        }
                        if (fmt.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                            channelCount = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceAtLeast(1)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
                            fmt.containsKey(MediaFormat.KEY_PCM_ENCODING)
                        ) {
                            pcmEncoding = fmt.getInteger(MediaFormat.KEY_PCM_ENCODING)
                        }
                    }
                    outIdx >= 0 -> {
                        val outBuf = dec.getOutputBuffer(outIdx)
                        if (outBuf != null && bufferInfo.size > 0) {
                            outBuf.position(bufferInfo.offset)
                            outBuf.limit(bufferInfo.offset + bufferInfo.size)
                            val converted = convertBufferToPcm16kMono(outBuf, bufferInfo.presentationTimeUs)
                            if (converted.isNotEmpty()) {
                                val needed = targetBytes - out.size()
                                if (converted.size <= needed) {
                                    out.write(converted)
                                } else {
                                    out.write(converted, 0, needed)
                                    val remain = converted.size - needed
                                    leftoverPcm = ByteArray(remain)
                                    System.arraycopy(converted, needed, leftoverPcm, 0, remain)
                                    leftoverOffset = 0
                                }
                            }
                        }
                        dec.releaseOutputBuffer(outIdx, false)
                        if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            outputDone = true
                        }
                    }
                }
            }

            val emittedBytes = out.toByteArray()
            val newSamples = emittedBytes.size / 2L
            emitted16kSamples += newSamples
            val chunkEndMs = anchorTimeMs + (emitted16kSamples * 1000L / 16000L)
            val isEof = outputDone && leftoverOffset >= leftoverPcm.size

            return mapOf(
                "pcm" to emittedBytes,
                "startMs" to chunkStartMs,
                "endMs" to chunkEndMs,
                "eof" to isEof,
            )
        }

        private fun convertBufferToPcm16kMono(buffer: ByteBuffer, ptsUs: Long): ByteArray {
            val ch = channelCount.coerceAtLeast(1)
            val isFloat = pcmEncoding == AudioFormat.ENCODING_PCM_FLOAT
            val bytesPerSample = if (isFloat) 4 else 2
            val bytesPerFrame = ch * bytesPerSample
            val totalFrames = buffer.remaining() / bytesPerFrame
            if (totalFrames <= 0) return ByteArray(0)

            var skipFrames = 0
            if (seekTargetUs > 0 && ptsUs < seekTargetUs) {
                val frameEndUs = ptsUs + (totalFrames.toLong() * 1_000_000L / sampleRate.toLong())
                if (frameEndUs <= seekTargetUs) {
                    return ByteArray(0)
                }
                skipFrames = (((seekTargetUs - ptsUs) * sampleRate.toLong()) / 1_000_000L)
                    .toInt()
                    .coerceIn(0, totalFrames)
                seekTargetUs = -1L
            } else if (seekTargetUs >= 0) {
                seekTargetUs = -1L
            }

            val keptFrames = totalFrames - skipFrames
            if (keptFrames <= 0) return ByteArray(0)

            buffer.order(ByteOrder.LITTLE_ENDIAN)
            if (skipFrames > 0) {
                buffer.position(buffer.position() + skipFrames * bytesPerFrame)
            }

            val ratio = sampleRate.toDouble() / 16000.0
            val estimatedOut = ((keptFrames / ratio) + 4).toInt().coerceAtLeast(4)
            val pcmOut = ByteArrayOutputStream(estimatedOut * 2)

            for (i in 0 until keptFrames) {
                var sum = 0.0
                for (c in 0 until ch) {
                    val sample = if (isFloat) {
                        (buffer.getFloat() * 32767.0).coerceIn(-32768.0, 32767.0)
                    } else {
                        buffer.getShort().toDouble()
                    }
                    sum += sample
                }
                val mono = sum / ch

                if (!hasPrevSample) {
                    prevMonoSample = mono
                    hasPrevSample = true
                }

                while (resamplePhase < 1.0) {
                    val interp = prevMonoSample + (mono - prevMonoSample) * resamplePhase
                    val intSample = interp.toInt().coerceIn(-32768, 32767)
                    pcmOut.write(intSample and 0xFF)
                    pcmOut.write((intSample shr 8) and 0xFF)
                    resamplePhase += ratio
                }
                resamplePhase -= 1.0
                prevMonoSample = mono
            }

            return pcmOut.toByteArray()
        }

        fun close() {
            closed = true
            synchronized(lock) {
                try {
                    codec?.stop()
                } catch (_: Exception) {}
                try {
                    codec?.release()
                } catch (_: Exception) {}
                try {
                    extractor?.release()
                } catch (_: Exception) {}
                codec = null
                extractor = null
                leftoverPcm = ByteArray(0)
                leftoverOffset = 0
            }
        }
    }

    private class AndroidLivePcmPlayer(
        private val channel: MethodChannel,
        private val mainHandler: Handler,
    ) {
        private data class PcmPacket(
            val generation: Int,
            val pcm: ByteArray,
            val sampleRate: Int,
        )

        private val queueLock = Object()
        private val trackLock = Any()
        private val queue = ArrayDeque<PcmPacket>()

        @Volatile
        private var disposed = false

        @Volatile
        private var paused = false

        @Volatile
        private var active = false

        @Volatile
        private var generation = 0

        @Volatile
        private var volume = 1.0f

        @Volatile
        private var playbackRate = 1.0f

        private var audioTrack: AudioTrack? = null
        private var currentSampleRate = 24000
        private var writtenFrames = 0L
        private var headBaselineFrames = 0L
        private var reportedPlaying = false

        private val writerThread = Thread(
            { runWriterLoop() },
            "CapSubLivePcmPlayer",
        ).apply {
            isDaemon = true
            start()
        }

        fun configure(sampleRate: Int, vol: Float, rate: Float) {
            if (disposed) return
            volume = vol.coerceIn(0.0f, 1.0f)
            playbackRate = rate.coerceIn(0.5f, 2.5f)
            val safeRate = sampleRate.coerceIn(8000, 48000)
            synchronized(queueLock) {
                active = true
                paused = false
                queueLock.notifyAll()
            }
            synchronized(trackLock) {
                val track = ensureTrackLocked(safeRate)
                applyVolumeAndRateLocked(track)
            }
        }

        fun enqueuePcm(pcm: ByteArray, sampleRate: Int) {
            if (disposed || pcm.isEmpty()) return
            val safeRate = sampleRate.coerceIn(8000, 48000)
            synchronized(queueLock) {
                active = true
                queue.addLast(PcmPacket(generation, pcm, safeRate))
                updatePlayingStateLocked(forcePlaying = !paused)
                queueLock.notifyAll()
            }
        }

        fun setVolume(vol: Float) {
            val clamped = vol.coerceIn(0.0f, 1.0f)
            volume = clamped
            synchronized(trackLock) {
                audioTrack?.let {
                    try {
                        it.setVolume(clamped)
                    } catch (_: Exception) {}
                }
            }
        }

        fun setPlaybackRate(rate: Float) {
            val clamped = rate.coerceIn(0.5f, 2.5f)
            playbackRate = clamped
            synchronized(trackLock) {
                audioTrack?.let { applyRateLocked(it) }
            }
        }

        fun setPaused(isPaused: Boolean) {
            synchronized(queueLock) {
                if (disposed) return
                paused = isPaused
                if (isPaused) {
                    updatePlayingStateLocked(forcePlaying = false)
                } else if (queue.isNotEmpty() || estimateRemainingBufferedFrames() > 0L) {
                    updatePlayingStateLocked(forcePlaying = true)
                }
                queueLock.notifyAll()
            }
            synchronized(trackLock) {
                val track = audioTrack ?: return
                try {
                    if (isPaused) {
                        if (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
                            track.pause()
                        }
                    } else if (active && !disposed) {
                        if (track.playState != AudioTrack.PLAYSTATE_PLAYING) {
                            track.play()
                        }
                    }
                } catch (_: Exception) {}
            }
        }

        fun interrupt() {
            synchronized(queueLock) {
                generation += 1
                paused = false
                queue.clear()
                updatePlayingStateLocked(forcePlaying = false)
                queueLock.notifyAll()
            }
            synchronized(trackLock) {
                val track = audioTrack ?: return
                try {
                    if (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
                        track.pause()
                    }
                    track.flush()
                    headBaselineFrames = track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
                } catch (_: Exception) {
                    headBaselineFrames = 0L
                }
                writtenFrames = 0L
            }
        }

        fun dispose() {
            synchronized(queueLock) {
                if (disposed) return
                disposed = true
                active = false
                generation += 1
                queue.clear()
                updatePlayingStateLocked(forcePlaying = false)
                queueLock.notifyAll()
            }
            try {
                writerThread.interrupt()
            } catch (_: Exception) {}
            synchronized(trackLock) {
                releaseTrackLocked()
            }
        }

        private fun runWriterLoop() {
            while (!disposed) {
                var packet: PcmPacket? = null
                synchronized(queueLock) {
                    while (!disposed && (paused || queue.isEmpty())) {
                        if (!paused && queue.isEmpty() && reportedPlaying) {
                            val remaining = estimateRemainingBufferedFrames()
                            if (remaining <= 0L) {
                                updatePlayingStateLocked(forcePlaying = false)
                                queueLock.wait()
                            } else {
                                queueLock.wait(80L)
                            }
                        } else {
                            queueLock.wait()
                        }
                    }
                    if (!disposed && queue.isNotEmpty() && !paused) {
                        packet = queue.removeFirst()
                    }
                }

                val current = packet ?: continue
                if (current.generation != generation || paused || disposed) continue

                val bytes = current.pcm
                val evenLen = bytes.size and 1.inv()
                if (evenLen <= 0) continue

                var offset = 0
                val sliceSize = 3840 // ~80ms ở 24kHz 16-bit mono để interrupt phản hồi nhanh
                while (offset < evenLen &&
                    !disposed &&
                    !paused &&
                    current.generation == generation
                ) {
                    val toWrite = minOf(sliceSize, evenLen - offset)
                    val written = synchronized(trackLock) {
                        if (disposed || paused || current.generation != generation) {
                            0
                        } else {
                            val track = ensureTrackLocked(current.sampleRate)
                            if (track.state != AudioTrack.STATE_INITIALIZED) {
                                -1
                            } else {
                                if (track.playState != AudioTrack.PLAYSTATE_PLAYING) {
                                    applyVolumeAndRateLocked(track)
                                    track.play()
                                }
                                val res = track.write(
                                    bytes,
                                    offset,
                                    toWrite,
                                    AudioTrack.WRITE_BLOCKING,
                                )
                                if (res > 0) {
                                    writtenFrames += (res / 2).toLong()
                                }
                                res
                            }
                        }
                    }
                    if (written <= 0) break
                    offset += written
                }
            }
        }

        private fun estimateRemainingBufferedFrames(): Long {
            synchronized(trackLock) {
                val track = audioTrack ?: return 0L
                return try {
                    val head = track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
                    val playedSinceReset = (head - headBaselineFrames).coerceAtLeast(0L)
                    (writtenFrames - playedSinceReset).coerceAtLeast(0L)
                } catch (_: Exception) {
                    0L
                }
            }
        }

        private fun ensureTrackLocked(sampleRate: Int): AudioTrack {
            val existing = audioTrack
            if (existing != null &&
                currentSampleRate == sampleRate &&
                existing.state == AudioTrack.STATE_INITIALIZED
            ) {
                return existing
            }
            releaseTrackLocked()
            currentSampleRate = sampleRate
            val minBuf = AudioTrack.getMinBufferSize(
                sampleRate,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            ).coerceAtLeast(4800)
            val bufferBytes = maxOf(minBuf * 3, sampleRate * 2) // Ít nhất 1 giây đệm vòng
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            val fmt = AudioFormat.Builder()
                .setSampleRate(sampleRate)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build()
            val track = AudioTrack.Builder()
                .setAudioAttributes(attrs)
                .setAudioFormat(fmt)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(bufferBytes)
                .build()
            audioTrack = track
            writtenFrames = 0L
            headBaselineFrames = 0L
            applyVolumeAndRateLocked(track)
            return track
        }

        private fun applyVolumeAndRateLocked(track: AudioTrack) {
            try {
                track.setVolume(volume)
            } catch (_: Exception) {}
            applyRateLocked(track)
        }

        private fun applyRateLocked(track: AudioTrack) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                try {
                    val params = try {
                        track.playbackParams
                    } catch (_: Exception) {
                        PlaybackParams()
                    }
                    params.speed = playbackRate
                    track.playbackParams = params
                } catch (_: Exception) {}
            }
        }

        private fun releaseTrackLocked() {
            val track = audioTrack ?: return
            audioTrack = null
            writtenFrames = 0L
            headBaselineFrames = 0L
            try {
                if (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
                    track.pause()
                }
                track.flush()
            } catch (_: Exception) {}
            try {
                track.release()
            } catch (_: Exception) {}
        }

        private fun updatePlayingStateLocked(forcePlaying: Boolean) {
            if (reportedPlaying != forcePlaying) {
                reportedPlaying = forcePlaying
                mainHandler.post {
                    if (!disposed) {
                        channel.invokeMethod("onPlaybackStateChanged", forcePlaying)
                    }
                }
            }
        }
    }
}
