package com.capcut.capsub_flutter

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.capcut.capsub/media"
    private val mediaExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
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
    }

    override fun onDestroy() {
        mediaExecutor.shutdownNow()
        super.onDestroy()
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
        } else {
            mapOf("User-Agent" to "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36")
        }
    }
}
