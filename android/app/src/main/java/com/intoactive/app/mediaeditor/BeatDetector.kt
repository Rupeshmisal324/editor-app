package com.intoactive.app.mediaeditor

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import java.nio.ByteOrder
import kotlin.math.ln
import kotlin.math.max

/**
 * Beat sync: a simple on-device beat finder (same idea as iOS
 * BeatDetector). Decodes the song, mixes to mono, measures loudness in
 * ~23 ms steps, and keeps the sudden rises (onsets) that stand out from
 * their surroundings, at least 0.28 s apart. Returns song times in ms.
 * Blocking — call off the main thread.
 */
internal object BeatDetector {
  fun beatsMs(context: Context, uri: Uri, maxSeconds: Int = 300): List<Long> {
    val extractor = MediaExtractor()
    var codec: MediaCodec? = null
    try {
      extractor.setDataSource(context, uri, null)
      val trackIndex = (0 until extractor.trackCount).firstOrNull {
        extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
      } ?: return emptyList()
      extractor.selectTrack(trackIndex)
      val format = extractor.getTrackFormat(trackIndex)
      val mime = format.getString(MediaFormat.KEY_MIME) ?: return emptyList()
      codec = MediaCodec.createDecoderByType(mime)
      codec.configure(format, null, null, 0)
      codec.start()
      var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
      var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
      val hopSeconds = 0.0232
      var hop = max(1, (sampleRate * hopSeconds).toInt())
      val energies = ArrayList<Double>()
      var acc = 0.0
      var count = 0
      var framesTotal = 0L
      val info = MediaCodec.BufferInfo()
      var inputDone = false
      var outputDone = false
      while (!outputDone && framesTotal < maxSeconds.toLong() * sampleRate) {
        if (!inputDone) {
          val inIndex = codec.dequeueInputBuffer(10_000)
          if (inIndex >= 0) {
            val buffer = codec.getInputBuffer(inIndex)!!
            val size = extractor.readSampleData(buffer, 0)
            if (size < 0) {
              codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
              inputDone = true
            } else {
              codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
              extractor.advance()
            }
          }
        }
        val outIndex = codec.dequeueOutputBuffer(info, 10_000)
        when {
          outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
            val out = codec.outputFormat
            sampleRate = out.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            channels = out.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            hop = max(1, (sampleRate * hopSeconds).toInt())
          }
          outIndex >= 0 -> {
            val out = codec.getOutputBuffer(outIndex)!!
            out.position(info.offset)
            out.limit(info.offset + info.size)
            val shorts = out.order(ByteOrder.nativeOrder()).asShortBuffer()
            val ch = max(1, channels)
            while (shorts.remaining() >= ch) {
              var mono = 0.0
              repeat(ch) { mono += shorts.get() / 32768.0 }
              mono /= ch
              acc += mono * mono
              count++
              framesTotal++
              if (count >= hop) {
                energies.add(acc / count)
                acc = 0.0
                count = 0
              }
            }
            codec.releaseOutputBuffer(outIndex, false)
            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
          }
        }
      }
      if (energies.size < 5) return emptyList()
      val onset = DoubleArray(energies.size)
      for (i in 1 until energies.size) {
        onset[i] = max(0.0, ln(energies[i] + 1e-7) - ln(energies[i - 1] + 1e-7))
      }
      val hopMs = hop * 1000.0 / sampleRate
      val window = 16
      val beats = ArrayList<Long>()
      var lastBeat = -1_000_000.0
      for (i in 1 until onset.size - 1) {
        if (onset[i] <= 0 || onset[i] < onset[i - 1] || onset[i] < onset[i + 1]) continue
        val lo = max(0, i - window)
        val hi = minOf(onset.size - 1, i + window)
        var mean = 0.0
        for (j in lo..hi) mean += onset[j]
        mean /= (hi - lo + 1)
        val t = i * hopMs
        if (onset[i] > mean * 1.8 + 0.05 && t - lastBeat >= 280) {
          beats.add(t.toLong())
          lastBeat = t
        }
      }
      return beats
    } catch (e: Exception) {
      return emptyList()
    } finally {
      runCatching { codec?.stop() }
      runCatching { codec?.release() }
      extractor.release()
    }
  }
}
