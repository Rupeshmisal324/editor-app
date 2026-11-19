package com.intoactive.app.mediaeditor

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.nio.ByteBuffer

/**
 * Fade in/out audio (export): a linear gain ramp from 0 over the first
 * [fadeInUs] and down to 0 over the last [fadeOutUs] of an item that plays
 * for [totalUs] (output time — put it after any speed change). 0 = no fade
 * on that side. Supports 16-bit and float PCM.
 */
@UnstableApi
internal class FadeAudioProcessor(
  private val fadeInUs: Long,
  private val fadeOutUs: Long,
  private val totalUs: Long,
  /** Voice-over ducking: gain [duckLevel] over [duckStartUs, duckEndUs]
   *  (item time, 150 ms ramps); duckEndUs <= duckStartUs = none. */
  private val duckStartUs: Long = 0,
  private val duckEndUs: Long = 0,
  private val duckLevel: Float = 1f,
) : BaseAudioProcessor() {
  private var framesDone = 0L

  override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
    if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT && inputAudioFormat.encoding != C.ENCODING_PCM_FLOAT) {
      throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
    }
    return inputAudioFormat
  }

  private fun gain(tUs: Long): Float {
    var g = 1f
    if (fadeInUs > 0 && tUs < fadeInUs) g = minOf(g, tUs.toFloat() / fadeInUs)
    if (fadeOutUs > 0 && tUs > totalUs - fadeOutUs) g = minOf(g, (totalUs - tUs).coerceAtLeast(0).toFloat() / fadeOutUs)
    if (duckEndUs > duckStartUs) {
      val ramp = 150_000L
      val duck = when {
        tUs in duckStartUs..duckEndUs -> duckLevel
        tUs in (duckStartUs - ramp) until duckStartUs -> duckLevel + (1f - duckLevel) * (duckStartUs - tUs).toFloat() / ramp
        tUs in (duckEndUs + 1)..(duckEndUs + ramp) -> duckLevel + (1f - duckLevel) * (tUs - duckEndUs).toFloat() / ramp
        else -> 1f
      }
      g *= duck
    }
    return g.coerceIn(0f, 1f)
  }

  override fun queueInput(inputBuffer: ByteBuffer) {
    val remaining = inputBuffer.remaining()
    if (remaining == 0) return
    val format = inputAudioFormat
    val out = replaceOutputBuffer(remaining)
    val frameBytes = format.bytesPerFrame
    val channels = format.channelCount
    val rate = format.sampleRate.coerceAtLeast(1)
    val isFloat = format.encoding == C.ENCODING_PCM_FLOAT
    while (inputBuffer.remaining() >= frameBytes) {
      val g = gain(framesDone * 1_000_000L / rate)
      repeat(channels) {
        if (isFloat) {
          out.putFloat(inputBuffer.float * g)
        } else {
          out.putShort((inputBuffer.short * g).toInt().coerceIn(-32768, 32767).toShort())
        }
      }
      framesDone++
    }
    // Any partial frame (shouldn't happen) is passed through unchanged.
    while (inputBuffer.hasRemaining()) out.put(inputBuffer.get())
    out.flip()
  }

  override fun onFlush() {
    framesDone = 0
  }

  override fun onReset() {
    framesDone = 0
  }
}
