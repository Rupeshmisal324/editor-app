package com.intoactive.app.mediaeditor

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.view.MotionEvent
import android.view.View
import org.json.JSONObject
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Tilt-shift / background blur (photo only, like Vignette/Sharpen): the
 * photo stays sharp inside a circle (RADIAL) or a band (LINEAR) and blurs
 * progressively outside it. All geometry is normalized to the photo itself
 * (not the screen), so the same value renders identically on the
 * downsampled preview and the full-res export. Mirrors iOS's PhotoBlur.
 */
internal data class PhotoBlur(
  val mode: Mode = Mode.OFF,
  /** Sharp-area center, 0..1 of the photo's width/height (top-left origin). */
  val centerX: Float = 0.5f,
  val centerY: Float = 0.5f,
  /** RADIAL: sharp radius. LINEAR: half the band height. Fraction of the shorter side. */
  val size: Float = 0.22f,
  /** LINEAR only: band angle in radians (0 = horizontal band). */
  val angle: Float = 0f,
  /** 0..1 → max blur radius (see MAX_BLUR_FRACTION). */
  val strength: Float = 0.6f,
) {
  enum class Mode { OFF, RADIAL, LINEAR }

  val isActive: Boolean get() = mode != Mode.OFF && strength > 0.001f

  fun toJson(): JSONObject = JSONObject().apply {
    put("mode", mode.name)
    put("centerX", centerX.toDouble())
    put("centerY", centerY.toDouble())
    put("size", size.toDouble())
    put("angle", angle.toDouble())
    put("strength", strength.toDouble())
  }

  companion object {
    const val MIN_SIZE = 0.04f
    const val MAX_SIZE = 0.9f
    /** Max blur radius as a fraction of the shorter side. */
    const val MAX_BLUR_FRACTION = 0.03f
    /** Blur ramps in over this many `size`s beyond the sharp edge. */
    const val FEATHER_FACTOR = 0.7f

    fun fromJson(obj: JSONObject?): PhotoBlur {
      if (obj == null) return PhotoBlur()
      return PhotoBlur(
        mode = runCatching { Mode.valueOf(obj.optString("mode")) }.getOrDefault(Mode.OFF),
        centerX = obj.optDouble("centerX", 0.5).toFloat(),
        centerY = obj.optDouble("centerY", 0.5).toFloat(),
        size = obj.optDouble("size", 0.22).toFloat(),
        angle = obj.optDouble("angle", 0.0).toFloat(),
        strength = obj.optDouble("strength", 0.6).toFloat(),
      )
    }

    /** Sharp radius / feather edge, in pixels of a photo with this shorter side. */
    fun innerOuter(blur: PhotoBlur, minSide: Float): Pair<Float, Float> {
      val inner = blur.size * minSide
      val outer = inner + max(blur.size * FEATHER_FACTOR, 0.05f) * minSide
      return inner to outer
    }
  }
}

internal object PhotoBlurRenderer {
  /** The blur itself runs on a downscaled copy (a box blur's cost grows
   *  with the radius); this is roughly the radius kept at that scale. */
  private const val TARGET_SMALL_RADIUS = 6f

  fun blurRadiusPx(blur: PhotoBlur, width: Int, height: Int): Float =
    blur.strength * PhotoBlur.MAX_BLUR_FRACTION * min(width, height)

  /** Downscaled, blurred copy of [src] — stretched back up by [composite]. */
  fun blurredSmallCopy(src: Bitmap, radiusPx: Float): Bitmap {
    val factor = (radiusPx / TARGET_SMALL_RADIUS).coerceIn(1f, 16f)
    val w = max(1, (src.width / factor).roundToInt())
    val h = max(1, (src.height / factor).roundToInt())
    val small = Bitmap.createScaledBitmap(src, w, h, true).copy(Bitmap.Config.ARGB_8888, true)
    val r = max(1, (radiusPx / factor).roundToInt())
    val pixels = IntArray(w * h)
    small.getPixels(pixels, 0, w, 0, 0, w, h)
    val scratch = IntArray(w * h)
    // 3 box passes ≈ a gaussian.
    repeat(3) {
      boxBlurHorizontal(pixels, scratch, w, h, r)
      boxBlurVertical(scratch, pixels, w, h, r)
    }
    small.setPixels(pixels, 0, w, 0, 0, w, h)
    return small
  }

  /** [sharp] with [blurredSmall] layered on top through the blur's mask.
   *  Draws into [reuse] when it's a mutable bitmap of the right size. */
  fun composite(sharp: Bitmap, blurredSmall: Bitmap, blur: PhotoBlur, reuse: Bitmap? = null): Bitmap {
    val w = sharp.width
    val h = sharp.height
    val out = reuse?.takeIf { it.isMutable && it.width == w && it.height == h && it !== sharp }
      ?: Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(out)
    canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
    canvas.drawBitmap(sharp, 0f, 0f, null)
    val bounds = RectF(0f, 0f, w.toFloat(), h.toFloat())
    val layer = canvas.saveLayer(bounds, null)
    canvas.drawBitmap(blurredSmall, null, bounds, Paint(Paint.FILTER_BITMAP_FLAG))
    val maskPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
      shader = maskShader(blur, w.toFloat(), h.toFloat())
      xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_IN)
    }
    canvas.drawRect(bounds, maskPaint)
    canvas.restoreToCount(layer)
    return out
  }

  /** One-shot (export): blur + composite into a new bitmap. */
  fun apply(src: Bitmap, blur: PhotoBlur): Bitmap {
    if (!blur.isActive) return src
    val small = blurredSmallCopy(src, blurRadiusPx(blur, src.width, src.height))
    return composite(src, small, blur).also { small.recycle() }
  }

  /** Alpha mask: transparent = sharp (keep the photo), opaque = blurred. */
  private fun maskShader(blur: PhotoBlur, w: Float, h: Float): Shader {
    val (inner, outer) = PhotoBlur.innerOuter(blur, min(w, h))
    val cx = blur.centerX * w
    val cy = blur.centerY * h
    val clear = Color.TRANSPARENT
    val solid = Color.BLACK
    return if (blur.mode == PhotoBlur.Mode.RADIAL) {
      RadialGradient(cx, cy, outer, intArrayOf(clear, clear, solid), floatArrayOf(0f, inner / outer, 1f), Shader.TileMode.CLAMP)
    } else {
      // Gradient runs along the band's normal; CLAMP keeps both far sides blurred.
      val nx = -sin(blur.angle)
      val ny = cos(blur.angle)
      LinearGradient(
        cx - nx * outer, cy - ny * outer, cx + nx * outer, cy + ny * outer,
        intArrayOf(solid, clear, clear, solid),
        floatArrayOf(0f, (outer - inner) / (2 * outer), (outer + inner) / (2 * outer), 1f),
        Shader.TileMode.CLAMP,
      )
    }
  }

  private fun boxBlurHorizontal(src: IntArray, dst: IntArray, w: Int, h: Int, r: Int) {
    val div = 2 * r + 1
    for (y in 0 until h) {
      val row = y * w
      var a = 0; var rr = 0; var g = 0; var b = 0
      for (i in -r..r) {
        val p = src[row + i.coerceIn(0, w - 1)]
        a += p ushr 24; rr += (p shr 16) and 0xFF; g += (p shr 8) and 0xFF; b += p and 0xFF
      }
      for (x in 0 until w) {
        dst[row + x] = ((a / div) shl 24) or ((rr / div) shl 16) or ((g / div) shl 8) or (b / div)
        val out = src[row + (x - r).coerceIn(0, w - 1)]
        val inn = src[row + (x + r + 1).coerceIn(0, w - 1)]
        a += (inn ushr 24) - (out ushr 24)
        rr += ((inn shr 16) and 0xFF) - ((out shr 16) and 0xFF)
        g += ((inn shr 8) and 0xFF) - ((out shr 8) and 0xFF)
        b += (inn and 0xFF) - (out and 0xFF)
      }
    }
  }

  private fun boxBlurVertical(src: IntArray, dst: IntArray, w: Int, h: Int, r: Int) {
    val div = 2 * r + 1
    for (x in 0 until w) {
      var a = 0; var rr = 0; var g = 0; var b = 0
      for (i in -r..r) {
        val p = src[i.coerceIn(0, h - 1) * w + x]
        a += p ushr 24; rr += (p shr 16) and 0xFF; g += (p shr 8) and 0xFF; b += p and 0xFF
      }
      for (y in 0 until h) {
        dst[y * w + x] = ((a / div) shl 24) or ((rr / div) shl 16) or ((g / div) shl 8) or (b / div)
        val out = src[(y - r).coerceIn(0, h - 1) * w + x]
        val inn = src[(y + r + 1).coerceIn(0, h - 1) * w + x]
        a += (inn ushr 24) - (out ushr 24)
        rr += ((inn shr 16) and 0xFF) - ((out shr 16) and 0xFF)
        g += ((inn shr 8) and 0xFF) - ((out shr 8) and 0xFF)
        b += (inn and 0xFF) - (out and 0xFF)
      }
    }
  }
}

/**
 * On-canvas guide + gestures for the Blur tool: one-finger drag moves the
 * sharp area, pinch resizes it, two-finger rotate turns a LINEAR band.
 * Laid out over the same (untransformed) box as the photo's ImageView;
 * geometry is edited in the photo's own local space via [photoMatrix]
 * (the ImageView's pan/zoom/rotate matrix), so it stays correct when the
 * photo is transformed.
 */
@SuppressLint("ViewConstructor")
internal class BlurFocusOverlayView(context: Context) : View(context) {
  var blur = PhotoBlur()
    set(value) { field = value; invalidate() }
  /** Photo-local → this view's coordinates. */
  var photoMatrix: (() -> Matrix)? = null
  /** Photo's untransformed size in px (the ImageView's own size). */
  var photoSize: (() -> Pair<Float, Float>)? = null
  var onChange: ((PhotoBlur) -> Unit)? = null
  var onGestureEnded: ((before: PhotoBlur, after: PhotoBlur) -> Unit)? = null

  private val density = resources.displayMetrics.density
  private val guidePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    color = Color.argb(230, 255, 255, 255)
    strokeWidth = 1.5f * density
    setShadowLayer(1.5f * density, 0f, 0f, Color.argb(128, 0, 0, 0))
  }
  private val featherPaint = Paint(guidePaint).apply {
    color = Color.argb(150, 255, 255, 255)
    pathEffect = DashPathEffect(floatArrayOf(6f * density, 5f * density), 0f)
  }
  private val fadePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.argb(72, 255, 255, 255)
  }
  private var showFade = false
  private var gestureStart: PhotoBlur? = null

  // Two-finger baselines (re-seeded whenever the pointer set changes).
  private var lastX = 0f
  private var lastY = 0f
  private var lastDistance = 0f
  private var lastAngle = 0f
  private var lastPointerCount = 0

  init {
    setLayerType(LAYER_TYPE_SOFTWARE, null) // shadowLayer on strokes
  }

  private fun size(): Pair<Float, Float> = photoSize?.invoke() ?: (width.toFloat() to height.toFloat())

  private fun matrix(): Matrix = photoMatrix?.invoke() ?: Matrix()

  private fun mapToView(x: Float, y: Float): FloatArray = floatArrayOf(x, y).also { matrix().mapPoints(it) }

  private fun mapToPhoto(x: Float, y: Float): FloatArray {
    val inverse = Matrix()
    matrix().invert(inverse)
    return floatArrayOf(x, y).also { inverse.mapPoints(it) }
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    if (blur.mode == PhotoBlur.Mode.OFF) return
    val (w, h) = size()
    val (inner, outer) = PhotoBlur.innerOuter(blur, min(w, h))
    val cx = blur.centerX * w
    val cy = blur.centerY * h
    val guide = Path()
    val feather = Path()
    val sharp = Path()
    if (blur.mode == PhotoBlur.Mode.RADIAL) {
      guide.addCircle(cx, cy, inner, Path.Direction.CW)
      feather.addCircle(cx, cy, outer, Path.Direction.CW)
      sharp.addCircle(cx, cy, inner, Path.Direction.CW)
    } else {
      val dx = cos(blur.angle); val dy = sin(blur.angle)
      val nx = -sin(blur.angle); val ny = cos(blur.angle)
      val length = (w + h) * 2
      fun line(offset: Float, path: Path) {
        val px = cx + nx * offset; val py = cy + ny * offset
        path.moveTo(px - dx * length, py - dy * length)
        path.lineTo(px + dx * length, py + dy * length)
      }
      line(inner, guide); line(-inner, guide)
      line(outer, feather); line(-outer, feather)
      val p1x = cx + nx * inner; val p1y = cy + ny * inner
      val p2x = cx - nx * inner; val p2y = cy - ny * inner
      sharp.moveTo(p1x - dx * length, p1y - dy * length)
      sharp.lineTo(p1x + dx * length, p1y + dy * length)
      sharp.lineTo(p2x + dx * length, p2y + dy * length)
      sharp.lineTo(p2x - dx * length, p2y - dy * length)
      sharp.close()
    }
    val m = matrix()
    guide.transform(m)
    feather.transform(m)
    sharp.transform(m)
    if (showFade) {
      // Whole overlay minus the sharp area = "this gets blurred".
      val fade = Path().apply {
        fillType = Path.FillType.EVEN_ODD
        addRect(0f, 0f, width.toFloat(), height.toFloat(), Path.Direction.CW)
        addPath(sharp)
      }
      canvas.drawPath(fade, fadePaint)
    }
    canvas.drawPath(feather, featherPaint)
    canvas.drawPath(guide, guidePaint)
  }

  private fun commit(newBlur: PhotoBlur) {
    blur = newBlur
    onChange?.invoke(newBlur)
  }

  private fun seedBaselines(event: MotionEvent) {
    lastPointerCount = event.pointerCount
    if (event.pointerCount >= 2) {
      lastX = (event.getX(0) + event.getX(1)) / 2
      lastY = (event.getY(0) + event.getY(1)) / 2
      lastDistance = hypot(event.getX(1) - event.getX(0), event.getY(1) - event.getY(0))
      lastAngle = atan2(event.getY(1) - event.getY(0), event.getX(1) - event.getX(0))
    } else {
      lastX = event.getX(0)
      lastY = event.getY(0)
    }
  }

  @SuppressLint("ClickableViewAccessibility")
  override fun onTouchEvent(event: MotionEvent): Boolean {
    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        gestureStart = blur
        showFade = true
        parent?.requestDisallowInterceptTouchEvent(true)
        seedBaselines(event)
        invalidate()
      }
      MotionEvent.ACTION_POINTER_DOWN -> seedBaselines(event)
      MotionEvent.ACTION_POINTER_UP -> {
        // Re-seed on the next MOVE with the remaining pointer(s).
        lastPointerCount = -1
      }
      MotionEvent.ACTION_MOVE -> {
        if (lastPointerCount != event.pointerCount) {
          seedBaselines(event)
          return true
        }
        val (w, h) = size()
        val x: Float
        val y: Float
        var newBlur = blur
        if (event.pointerCount >= 2) {
          x = (event.getX(0) + event.getX(1)) / 2
          y = (event.getY(0) + event.getY(1)) / 2
          val distance = hypot(event.getX(1) - event.getX(0), event.getY(1) - event.getY(0))
          val angle = atan2(event.getY(1) - event.getY(0), event.getX(1) - event.getX(0))
          if (lastDistance > 0f) {
            newBlur = newBlur.copy(size = (newBlur.size * distance / lastDistance).coerceIn(PhotoBlur.MIN_SIZE, PhotoBlur.MAX_SIZE))
          }
          if (newBlur.mode == PhotoBlur.Mode.LINEAR) {
            newBlur = newBlur.copy(angle = newBlur.angle + (angle - lastAngle))
          }
          lastDistance = distance
          lastAngle = angle
        } else {
          x = event.getX(0)
          y = event.getY(0)
        }
        // Pan: move the center by the finger delta, measured in view space.
        val centerInView = mapToView(newBlur.centerX * w, newBlur.centerY * h)
        val moved = mapToPhoto(centerInView[0] + (x - lastX), centerInView[1] + (y - lastY))
        newBlur = newBlur.copy(
          centerX = (moved[0] / max(w, 1f)).coerceIn(0f, 1f),
          centerY = (moved[1] / max(h, 1f)).coerceIn(0f, 1f),
        )
        lastX = x
        lastY = y
        commit(newBlur)
      }
      MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
        showFade = false
        invalidate()
        gestureStart?.let { onGestureEnded?.invoke(it, blur) }
        gestureStart = null
      }
    }
    return true
  }
}
