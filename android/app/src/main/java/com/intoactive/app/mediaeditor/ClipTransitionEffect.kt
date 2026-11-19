package com.intoactive.app.mediaeditor

import android.content.Context
import android.opengl.GLES20
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram

/**
 * Transitions (roadmap row 33) for one exported item: over its first
 * [TRANSITION_DURATION_US] ([inType]) and last ([outType]) the video frame
 * fades to / from black, slides, or zooms. No overlap between clips, so
 * the timeline length is unchanged. Same look as iOS
 * MediaEditorVideoCompositor.applyTransition. Types: 0 none, 1 fade,
 * 2 slide, 3 zoom. [itemDurationUs] = the item's OUTPUT length.
 * Time is measured from the item's first frame (each item gets its own
 * instance), like TimedBitmapOverlay.
 */
@UnstableApi
internal class ClipTransitionEffect(
  private val inType: Int,
  private val outType: Int,
  private val itemDurationUs: Long,
) : GlEffect {
  override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
    ClipTransitionShaderProgram(inType, outType, itemDurationUs, useHdr)

  override fun isNoOp(inputWidth: Int, inputHeight: Int): Boolean = inType == 0 && outType == 0

  companion object {
    const val TRANSITION_DURATION_US = 400_000L
  }
}

@UnstableApi
private class ClipTransitionShaderProgram(
  private val inType: Int,
  private val outType: Int,
  private val itemDurationUs: Long,
  useHdr: Boolean,
) : BaseGlShaderProgram(/* useHighPrecisionColorComponents= */ useHdr, /* texturePoolCapacity= */ 1) {
  private val glProgram: GlProgram = try {
    GlProgram(VERTEX_SHADER, FRAGMENT_SHADER)
  } catch (e: GlUtil.GlException) {
    throw VideoFrameProcessingException(e)
  }
  private var firstFrameUs = Long.MIN_VALUE

  init {
    glProgram.setBufferAttribute(
      "aFramePosition",
      GlUtil.getNormalizedCoordinateBounds(),
      GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
    )
  }

  override fun configure(inputWidth: Int, inputHeight: Int): Size = Size(inputWidth, inputHeight)

  override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
    if (firstFrameUs == Long.MIN_VALUE) firstFrameUs = presentationTimeUs
    val local = (presentationTimeUs - firstFrameUs).coerceAtLeast(0)
    val d = ClipTransitionEffect.TRANSITION_DURATION_US
    var type = 0
    var amount = 0f
    var incoming = false
    if (inType != 0 && local < d) {
      type = inType; amount = 1f - local.toFloat() / d; incoming = true
    } else if (outType != 0 && local > itemDurationUs - d) {
      type = outType; amount = 1f - ((itemDurationUs - local).coerceAtLeast(0)).toFloat() / d
    }
    amount = amount.coerceIn(0f, 1f)
    var alpha = 1f
    var scale = 1f
    var offset = 0f
    when (type) {
      1 -> alpha = 1f - amount
      2 -> offset = amount * (if (incoming) 1f else -1f)
      3 -> { alpha = 1f - amount; scale = 1f + 0.25f * amount }
    }
    try {
      glProgram.use()
      glProgram.setSamplerTexIdUniform("uTexSampler", inputTexId, /* texUnitIndex= */ 0)
      glProgram.setFloatUniform("uAlpha", alpha)
      glProgram.setFloatUniform("uScale", scale)
      glProgram.setFloatUniform("uOffset", offset)
      glProgram.bindAttributesAndUniforms()
      GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, /* first= */ 0, /* count= */ 4)
    } catch (e: GlUtil.GlException) {
      throw VideoFrameProcessingException(e, presentationTimeUs)
    }
  }

  override fun release() {
    super.release()
    try {
      glProgram.delete()
    } catch (e: GlUtil.GlException) {
      throw VideoFrameProcessingException(e)
    }
  }

  companion object {
    private const val VERTEX_SHADER = """
attribute vec4 aFramePosition;
varying vec2 vTexSamplingCoord;
void main() {
  gl_Position = aFramePosition;
  vTexSamplingCoord = vec2(aFramePosition.x * 0.5 + 0.5, aFramePosition.y * 0.5 + 0.5);
}
"""

    private const val FRAGMENT_SHADER = """
precision highp float;
uniform sampler2D uTexSampler;
uniform float uAlpha;
uniform float uScale;
uniform float uOffset;
varying vec2 vTexSamplingCoord;
void main() {
  vec2 uv = (vTexSamplingCoord - 0.5 - vec2(uOffset, 0.0)) / uScale + 0.5;
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
    gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
  } else {
    vec4 c = texture2D(uTexSampler, uv);
    gl_FragColor = vec4(c.rgb * uAlpha, 1.0);
  }
}
"""
  }
}
