package com.intoactive.app.mediaeditor

import android.graphics.Bitmap
import android.graphics.BlendMode
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PointF
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.os.Build
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

// Overlay (added photo) look: filter + adjust, opacity, blend, shape,
// border, flip and eraser. One renderer for preview, export and re-edit.
// Line-by-line port of iOS's OverlayKit.swift — change both together.

enum class OverlayBlendMode(val title: String) {
  NORMAL("Normal"), MULTIPLY("Multiply"), SCREEN("Screen"), OVERLAY("Overlay"),
  DARKEN("Darken"), LIGHTEN("Lighten"), SOFT_LIGHT("Soft light");

  /** Sets [paint] to draw with this blend mode (null for NORMAL). On
   *  Android 9 and below, Multiply/Soft light fall back to the nearest
   *  Porter-Duff mode that keeps transparent areas transparent. */
  fun applyTo(paint: Paint) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      paint.blendMode = when (this) {
        NORMAL -> null
        MULTIPLY -> BlendMode.MULTIPLY
        SCREEN -> BlendMode.SCREEN
        OVERLAY -> BlendMode.OVERLAY
        DARKEN -> BlendMode.DARKEN
        LIGHTEN -> BlendMode.LIGHTEN
        SOFT_LIGHT -> BlendMode.SOFT_LIGHT
      }
    } else {
      paint.xfermode = when (this) {
        NORMAL -> null
        MULTIPLY, DARKEN -> PorterDuffXfermode(PorterDuff.Mode.DARKEN)
        SCREEN -> PorterDuffXfermode(PorterDuff.Mode.SCREEN)
        OVERLAY, SOFT_LIGHT -> PorterDuffXfermode(PorterDuff.Mode.OVERLAY)
        LIGHTEN -> PorterDuffXfermode(PorterDuff.Mode.LIGHTEN)
      }
    }
  }
}

enum class OverlayShape(val title: String) {
  NONE("None"), ROUNDED("Rounded"), CIRCLE("Circle"), HEART("Heart"), STAR("Star"), HEXAGON("Hexagon"),
}

/** Enum names are saved in re-edit projects — never rename one. */
internal data class OverlayStyle(
  val filter: PhotoFilter = PhotoFilter.ORIGINAL,
  val filterStrength: Float = 1f,
  /** -1…1 each. */
  val brightness: Float = 0f,
  val contrast: Float = 0f,
  val saturation: Float = 0f,
  val warmth: Float = 0f,
  val opacity: Float = 1f,
  val blend: OverlayBlendMode = OverlayBlendMode.NORMAL,
  val shape: OverlayShape = OverlayShape.NONE,
  /** 0…1 (× 8% of the shorter side). */
  val border: Float = 0f,
  val borderColor: Int = Color.WHITE,
  val flipX: Boolean = false,
  val flipY: Boolean = false,
) {
  /** Everything that changes the colour pass (cached separately so eraser
   *  strokes don't re-run filters). */
  val colorKey: String get() = "${filter.name}|$filterStrength|$brightness|$contrast|$saturation|$warmth"
}

/** One eraser (or restore) stroke, in the overlay's own box: points are
 *  0…1 of its width/height, width is a fraction of its width. */
data class OverlayEraseStroke(val points: List<PointF>, val width: Float, val restore: Boolean)

internal object OverlayRenderer {
  const val BORDER_MAX_WIDTH = 0.08f
  const val ROUNDED_CORNER_RADIUS = 0.18f
  /** Long side the on-screen preview is processed at. */
  const val PREVIEW_MAX_SIDE = 1024

  /** Brightness/contrast/saturation/warmth as one 4×5 matrix on sRGB
   *  values (offsets in 0…255) — same numbers as iOS's adjustMatrix. */
  fun adjustMatrix(style: OverlayStyle): ColorMatrix {
    val s = 1f + style.saturation
    val lr = 0.2126f
    val lg = 0.7152f
    val lb = 0.0722f
    val k = 1f + style.contrast * 0.6f
    val offset = (0.5f * (1f - k) + style.brightness * 0.25f) * 255f
    val warm = style.warmth * 0.08f * 255f
    return ColorMatrix(floatArrayOf(
      (lr * (1 - s) + s) * k, lg * (1 - s) * k, lb * (1 - s) * k, 0f, offset + warm,
      lr * (1 - s) * k, (lg * (1 - s) + s) * k, lb * (1 - s) * k, 0f, offset,
      lr * (1 - s) * k, lg * (1 - s) * k, (lb * (1 - s) + s) * k, 0f, offset - warm,
      0f, 0f, 0f, 1f, 0f,
    ))
  }

  /** Filtered + adjusted copy of [base], at most [maxSide] px long. */
  fun colorPass(base: Bitmap, style: OverlayStyle, maxSide: Int): Bitmap {
    var current = downscaled(base, maxSide)
    if (style.filter != PhotoFilter.ORIGINAL) {
      current = if (style.filter.category == FilterCategory.ARTISTIC) {
        ArtisticEffects.blend(current, ArtisticEffects.render(style.filter, current), style.filterStrength, 0f)
      } else {
        FilterLut.apply(current, FilterLut.baked(FilterLut.keyFor(style.filter, style.filterStrength, 0f)))
      }
    }
    if (style.brightness == 0f && style.contrast == 0f && style.saturation == 0f && style.warmth == 0f) return current
    val out = Bitmap.createBitmap(current.width, current.height, Bitmap.Config.ARGB_8888)
    Canvas(out).drawBitmap(current, 0f, 0f, Paint().apply { colorFilter = ColorMatrixColorFilter(adjustMatrix(style)) })
    return out
  }

  private fun downscaled(bitmap: Bitmap, maxSide: Int): Bitmap {
    val scale = min(1f, maxSide.toFloat() / max(bitmap.width, bitmap.height))
    if (scale >= 1f) return bitmap
    return Bitmap.createScaledBitmap(bitmap, (bitmap.width * scale).roundToInt().coerceAtLeast(1), (bitmap.height * scale).roundToInt().coerceAtLeast(1), true)
  }

  /** The shape's outline inside [rect] (null = the plain rectangle).
   *  Circle/heart/star/hexagon use the centred square. */
  fun shapePath(shape: OverlayShape, rect: RectF): Path? {
    val side = min(rect.width(), rect.height())
    val square = RectF(rect.centerX() - side / 2, rect.centerY() - side / 2, rect.centerX() + side / 2, rect.centerY() + side / 2)
    fun polygon(points: List<PointF>): Path = Path().apply {
      points.forEachIndexed { i, p -> if (i == 0) moveTo(p.x, p.y) else lineTo(p.x, p.y) }
      close()
    }
    return when (shape) {
      OverlayShape.NONE -> null
      OverlayShape.ROUNDED -> Path().apply { addRoundRect(rect, side * ROUNDED_CORNER_RADIUS, side * ROUNDED_CORNER_RADIUS, Path.Direction.CW) }
      OverlayShape.CIRCLE -> Path().apply { addOval(square, Path.Direction.CW) }
      OverlayShape.HEART -> polygon(DrawingCanvasView.shapePolylines(DrawingCanvasView.ShapeType.HEART, PointF(square.left, square.top), PointF(square.right, square.bottom), 0f)[0])
      OverlayShape.STAR -> polygon(DrawingCanvasView.shapePolylines(DrawingCanvasView.ShapeType.STAR, PointF(square.left, square.top), PointF(square.right, square.bottom), 0f)[0])
      OverlayShape.HEXAGON -> polygon((0 until 6).map { i ->
        val angle = -PI.toFloat() / 2f + i * PI.toFloat() / 3f
        PointF(square.centerX() + side / 2 * cos(angle), square.centerY() + side / 2 * sin(angle))
      })
    }
  }

  /** The finished overlay at width×height: colour pass (precomputed),
   *  flipped, eraser applied, cut to its shape, bordered, at its opacity.
   *  Blend mode is NOT applied here — it's how the result is drawn onto
   *  the photo (export) or composited on screen (preview). */
  fun composite(colored: Bitmap, style: OverlayStyle, strokes: List<OverlayEraseStroke>, width: Int, height: Int): Bitmap {
    val out = Bitmap.createBitmap(width.coerceAtLeast(1), height.coerceAtLeast(1), Bitmap.Config.ARGB_8888)
    val canvas = Canvas(out)
    val rect = RectF(0f, 0f, width.toFloat(), height.toFloat())
    val bitmapPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    canvas.saveLayerAlpha(rect, (style.opacity.coerceIn(0f, 1f) * 255).roundToInt())
    val shape = shapePath(style.shape, rect)
    shape?.let { canvas.clipPath(it) }

    fun drawPhoto() {
      canvas.save()
      canvas.scale(if (style.flipX) -1f else 1f, if (style.flipY) -1f else 1f, rect.centerX(), rect.centerY())
      canvas.drawBitmap(colored, null, rect, bitmapPaint)
      canvas.restore()
    }

    canvas.saveLayer(rect, null)
    drawPhoto()
    val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
      this.style = Paint.Style.STROKE
      strokeCap = Paint.Cap.ROUND
      strokeJoin = Paint.Join.ROUND
    }
    for (stroke in strokes) {
      if (stroke.points.isEmpty()) continue
      val path = Path()
      stroke.points.forEachIndexed { i, p ->
        if (i == 0) path.moveTo(p.x * width, p.y * height) else path.lineTo(p.x * width, p.y * height)
      }
      if (stroke.points.size == 1) path.lineTo(stroke.points[0].x * width + 0.01f, stroke.points[0].y * height)
      strokePaint.strokeWidth = max(stroke.width * width, 1f)
      if (stroke.restore) {
        val outline = Path()
        strokePaint.getFillPath(path, outline)
        canvas.save()
        canvas.clipPath(outline)
        drawPhoto()
        canvas.restore()
      } else {
        strokePaint.xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR)
        canvas.drawPath(path, strokePaint)
        strokePaint.xfermode = null
      }
    }
    canvas.restore()

    if (style.border > 0.001f) {
      // Stroked twice as wide and clipped by the shape: the inner half shows.
      val borderWidth = BORDER_MAX_WIDTH * min(width, height) * style.border
      canvas.drawPath(shape ?: Path().apply { addRect(rect, Path.Direction.CW) }, Paint(Paint.ANTI_ALIAS_FLAG).apply {
        this.style = Paint.Style.STROKE
        color = style.borderColor
        strokeWidth = borderWidth * 2
        strokeJoin = Paint.Join.ROUND
      })
    }
    canvas.restore()
    return out
  }

  /** Full render at width×height (export): colour pass at that size. */
  fun render(base: Bitmap, style: OverlayStyle, strokes: List<OverlayEraseStroke>, width: Int, height: Int): Bitmap {
    val colored = colorPass(base, style, max(width, height).coerceAtLeast(1))
    return composite(colored, style, strokes, width, height)
  }
}

/** Transparent touch catcher for the overlay eraser (see
 *  MediaEditorActivity.updateOverlayEraseCapture). */
class OverlayEraseCaptureView(context: android.content.Context) : android.view.View(context) {
  /** (x, y in this view's own coordinates, is the first touch of a stroke) */
  var onTouch: ((Float, Float, Boolean) -> Unit)? = null

  override fun onTouchEvent(event: android.view.MotionEvent): Boolean {
    when (event.actionMasked) {
      android.view.MotionEvent.ACTION_DOWN -> onTouch?.invoke(event.x, event.y, true)
      android.view.MotionEvent.ACTION_MOVE -> onTouch?.invoke(event.x, event.y, false)
    }
    return true
  }
}
