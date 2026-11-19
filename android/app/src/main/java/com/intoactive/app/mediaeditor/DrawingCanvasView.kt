package com.intoactive.app.mediaeditor

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PointF
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.random.Random

/**
 * Freehand draw/brush layer — sized and positioned to exactly match the
 * photo canvas (imageView's own box, see MediaEditorActivity.layoutImageCanvas),
 * so a raw touch point recorded here is already in the SAME local coordinate
 * space as the photo, needing only a straight `* exportScale` at export time.
 *
 * Only intercepts touches while [isDrawingEnabled] is true (the Draw tab is
 * selected).
 *
 * Every stroke — live preview, photo export, video export, brush tile
 * previews — is drawn by [drawStrokes]/[drawStroke], so they always match.
 * Line-by-line port of iOS's DrawingCanvasView.swift (same brushes,
 * constants and pattern hash): change both together.
 */
class DrawingCanvasView(context: Context) : View(context) {

  /** Names are saved in re-edit projects — never rename one. ERASER clears
   *  earlier strokes (never the photo — strokes are always drawn into their
   *  own transparent layer). */
  enum class BrushType(val title: String) {
    PEN("Pen"), MARKER("Marker"), HIGHLIGHTER("Highlighter"), NEON("Neon"),
    DOTTED("Dotted"), SPRAY("Spray"), CHALK("Chalk"), SQUARES("Squares"),
    ERASER("Eraser"),
  }

  /** Drag-to-size shapes, outlined with the selected brush. Names are
   *  saved in re-edit projects — never rename one. */
  enum class ShapeType(val title: String) {
    LINE("Line"), ARROW("Arrow"), RECTANGLE("Rectangle"), OVAL("Oval"),
    TRIANGLE("Triangle"), STAR("Star"), HEART("Heart"),
  }

  /** Reference type so undo/redo can remove the exact instance. [seed]
   *  fixes the random texture (spray/chalk/squares) so it's identical on
   *  every redraw, in the export, and after re-opening the project. */
  class Stroke(
    var points: List<PointF>,
    val color: Int,
    var widthPx: Float,
    val brushType: BrushType = BrushType.PEN,
    val seed: Int = 0,
    /** Non-null for a shape: [points] is then just [drag start, drag end]. */
    val shape: ShapeType? = null,
  )

  private val strokes = mutableListOf<Stroke>()
  private val currentPoints = mutableListOf<PointF>()
  private var currentSeed = 0

  var currentColor: Int = Color.WHITE
  var currentWidthPx: Float = 12f
  var currentBrushType: BrushType = BrushType.PEN
  /** Non-null while the Shape tool is active: a drag draws this shape. */
  var currentShape: ShapeType? = null
  var isDrawingEnabled: Boolean = false

  /** Committed strokes rendered once, so a long drawing doesn't re-render
   *  every stroke on every finger move. Rebuilt when strokes change. */
  private var committedBitmap: Bitmap? = null

  /** Fired once a stroke is committed (finger lifted). */
  var onStrokeFinished: ((Stroke) -> Unit)? = null

  fun allStrokes(): List<Stroke> = strokes

  fun addStroke(stroke: Stroke) {
    strokes.add(stroke)
    invalidateCommitted()
  }

  fun removeStroke(stroke: Stroke) {
    strokes.remove(stroke)
    invalidateCommitted()
  }

  private fun invalidateCommitted() {
    committedBitmap = null
    invalidate()
  }

  override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
    super.onSizeChanged(w, h, oldw, oldh)
    invalidateCommitted()
  }

  /** Scales strokes in place when the canvas resizes, keeping the same
   *  instances so undo/redo identity still works. */
  fun rescaleForCanvasResize(factor: Float) {
    if (factor == 1f) return
    strokes.forEach { stroke ->
      stroke.points = stroke.points.map { PointF(it.x * factor, it.y * factor) }
      stroke.widthPx *= factor
    }
    val rescaledCurrent = currentPoints.map { PointF(it.x * factor, it.y * factor) }
    currentPoints.clear()
    currentPoints.addAll(rescaledCurrent)
    invalidateCommitted()
  }

  override fun onTouchEvent(event: MotionEvent): Boolean {
    if (!isDrawingEnabled) return false
    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        currentPoints.clear()
        currentPoints.add(PointF(event.x, event.y))
        currentSeed = Random.nextInt(1, Int.MAX_VALUE)
      }
      MotionEvent.ACTION_MOVE -> {
        if (currentShape != null && currentPoints.isNotEmpty()) {
          val start = currentPoints[0]
          currentPoints.clear()
          currentPoints.add(start)
        }
        currentPoints.add(PointF(event.x, event.y))
        invalidate()
      }
      MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
        if (currentPoints.size > 1 && (currentShape == null || dragLength(currentPoints) > 4f * resources.displayMetrics.density)) {
          val stroke = Stroke(currentPoints.toList(), currentColor, currentWidthPx, currentBrushType, currentSeed, currentShape)
          strokes.add(stroke)
          // Bake it into the cached bitmap instead of re-rendering everything.
          committedBitmap?.let { drawStroke(Canvas(it), stroke, 1f) }
          onStrokeFinished?.invoke(stroke)
        }
        currentPoints.clear()
        invalidate()
      }
    }
    return true
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    if (committedBitmap == null && strokes.isNotEmpty() && width > 0 && height > 0) {
      committedBitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also { bitmap ->
        val c = Canvas(bitmap)
        strokes.forEach { drawStroke(c, it, 1f) }
      }
    }
    // Own layer, so the live eraser stroke only clears drawing.
    val layer = canvas.saveLayer(0f, 0f, width.toFloat(), height.toFloat(), null)
    committedBitmap?.let { canvas.drawBitmap(it, 0f, 0f, null) }
    if (currentPoints.size > 1) {
      drawStroke(canvas, Stroke(currentPoints, currentColor, currentWidthPx, currentBrushType, currentSeed, currentShape), 1f)
    }
    canvas.restoreToCount(layer)
  }

  companion object {
    /** Draws [strokes] in order into their OWN layer, so an eraser stroke
     *  clears earlier strokes but not whatever [canvas] already holds (the
     *  photo, in photo export). Used by photo/video export. */
    fun drawStrokes(canvas: Canvas, strokes: List<Stroke>, scale: Float) {
      val layer = canvas.saveLayer(null, null)
      strokes.forEach { drawStroke(canvas, it, scale) }
      canvas.restoreToCount(layer)
    }

    private fun withAlpha(color: Int, alpha: Float): Int =
      (color and 0x00FFFFFF) or ((Color.alpha(color) * alpha).roundToInt().coerceIn(0, 255) shl 24)

    /** One stroke, with points/width in canvas px multiplied by [scale]. */
    fun drawStroke(canvas: Canvas, stroke: Stroke, scale: Float) {
      if (stroke.points.size <= 1) return
      val width = stroke.widthPx * scale
      val color = stroke.color
      // Freehand = one smoothed polyline; a shape = straight-edged outline(s).
      val shape = stroke.shape
      val polylines: List<List<PointF>>
      val path: Path
      if (shape != null) {
        polylines = shapePolylines(shape, stroke.points.first(), stroke.points.last(), stroke.widthPx)
        path = Path()
        for (line in polylines) {
          if (line.isEmpty()) continue
          path.moveTo(line[0].x * scale, line[0].y * scale)
          for (i in 1 until line.size) path.lineTo(line[i].x * scale, line[i].y * scale)
        }
      } else {
        polylines = listOf(stroke.points)
        path = buildSmoothedPath(stroke.points, scale)
      }
      val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeJoin = Paint.Join.ROUND
        strokeCap = Paint.Cap.ROUND
      }

      fun strokePath(c: Int, w: Float, cap: Paint.Cap = Paint.Cap.ROUND) {
        paint.color = c
        paint.strokeWidth = w
        paint.strokeCap = cap
        canvas.drawPath(path, paint)
      }

      when (stroke.brushType) {
        BrushType.PEN -> strokePath(color, width)
        BrushType.MARKER -> strokePath(withAlpha(color, 0.78f), width, Paint.Cap.SQUARE)
        BrushType.HIGHLIGHTER -> strokePath(withAlpha(color, 0.35f), width, Paint.Cap.SQUARE)
        BrushType.NEON -> {
          // Soft glow from wide translucent passes, then a bright core — no
          // blur, which wouldn't scale with the export.
          strokePath(withAlpha(color, 0.12f), width * 2.6f)
          strokePath(withAlpha(color, 0.25f), width * 1.8f)
          strokePath(color, width)
          strokePath(withAlpha(Color.WHITE, 0.9f), width * 0.35f)
        }
        BrushType.DOTTED -> {
          paint.pathEffect = DashPathEffect(floatArrayOf(0.001f, width * 1.9f), 0f)
          strokePath(color, width)
          paint.pathEffect = null
        }
        BrushType.SPRAY -> {
          val dots = scatter(polylines, stroke, scale, spacing = 0.3f, perSample = 8) { random, sx, sy ->
            val r = stroke.widthPx * 1.2f * sqrt(random(0))
            val angle = random(1) * 2f * PI.toFloat()
            Dot(sx + r * cos(angle), sy + r * sin(angle), stroke.widthPx * (0.04f + 0.06f * random(2)), false)
          }
          fillDots(canvas, dots, withAlpha(color, 0.85f))
        }
        BrushType.CHALK -> {
          strokePath(withAlpha(color, 0.35f), width)
          val dots = scatter(polylines, stroke, scale, spacing = 0.15f, perSample = 6) { random, sx, sy ->
            val r = stroke.widthPx * 0.5f * sqrt(random(0))
            val angle = random(1) * 2f * PI.toFloat()
            Dot(sx + r * cos(angle), sy + r * sin(angle), stroke.widthPx * (0.05f + 0.07f * random(2)), false)
          }
          fillDots(canvas, dots, withAlpha(color, 0.75f))
        }
        BrushType.SQUARES -> {
          val dots = scatter(polylines, stroke, scale, spacing = 0.9f, perSample = 1) { random, sx, sy ->
            val w = stroke.widthPx
            Dot(sx + (random(0) - 0.5f) * 1.8f * w, sy + (random(1) - 0.5f) * 1.8f * w, w * (0.25f + 0.45f * random(2)) / 2f, true)
          }
          fillDots(canvas, dots, withAlpha(color, 0.9f))
        }
        BrushType.ERASER -> {
          paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR)
          strokePath(Color.BLACK, width)
        }
      }
    }

    /** Centre and radius (half side for squares) in canvas px, pre-scale. */
    private class Dot(val x: Float, val y: Float, val radius: Float, val isSquare: Boolean)

    /** Dots (or squares) along the stroke. Positions come from points
     *  sampled every `spacing × width` along the raw touch polyline (canvas
     *  px, before [scale]) and a hash of (seed, sample, dot) — so the
     *  texture doesn't depend on export scale. Returns scaled dots. */
    private fun scatter(
      polylines: List<List<PointF>>,
      stroke: Stroke,
      scale: Float,
      spacing: Float,
      perSample: Int,
      place: (random: (Int) -> Float, sx: Float, sy: Float) -> Dot,
    ): List<Dot> {
      val step = max(stroke.widthPx * spacing, 0.5f)
      val result = mutableListOf<Dot>()
      polylines.flatMap { samples(it, step) }.forEachIndexed { sampleIndex, sample ->
        for (dot in 0 until perSample) {
          val random = { k: Int -> hashFraction(stroke.seed, sampleIndex, dot * 3 + k) }
          val d = place(random, sample.x, sample.y)
          result.add(Dot(d.x * scale, d.y * scale, d.radius * scale, d.isSquare))
        }
      }
      return result
    }

    private fun fillDots(canvas: Canvas, dots: List<Dot>, color: Int) {
      val path = Path()
      val rect = RectF()
      for (d in dots) {
        rect.set(d.x - d.radius, d.y - d.radius, d.x + d.radius, d.y + d.radius)
        if (d.isSquare) path.addRect(rect, Path.Direction.CW) else path.addOval(rect, Path.Direction.CW)
      }
      val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        this.color = color
      }
      // Winding fill, same as Core Graphics' default fillPath.
      path.fillType = Path.FillType.WINDING
      canvas.drawPath(path, paint)
    }

    /** Points every [spacing] along the polyline, starting at its first point. */
    private fun samples(points: List<PointF>, spacing: Float): List<PointF> {
      if (points.isEmpty()) return emptyList()
      val result = mutableListOf(points[0])
      var carried = 0f // distance walked since the last sample
      for (i in 1 until points.size) {
        val a = points[i - 1]
        val b = points[i]
        val segment = hypot(b.x - a.x, b.y - a.y)
        if (segment <= 0f) continue
        var t = spacing - carried
        while (t <= segment) {
          result.add(PointF(a.x + (b.x - a.x) * t / segment, a.y + (b.y - a.y) * t / segment))
          t += spacing
        }
        carried = segment - (t - spacing)
      }
      return result
    }

    /** Deterministic 0..<1 from three integers — same 32-bit operations as
     *  iOS's hashFraction (Int multiplication wraps like UInt32 &*). */
    fun hashFraction(a: Int, b: Int, c: Int): Float {
      var h = (a * 0x9E3779B1.toInt()) xor (b * 0x85EBCA77.toInt()) xor (c * 0xC2B2AE3D.toInt())
      h = h xor (h ushr 15)
      h *= 0x2C1B3C6D
      h = h xor (h ushr 12)
      h *= 0x297A2D39
      h = h xor (h ushr 15)
      return (h and 0xFFFFFF) / 16_777_216f
    }

    /** A small sample stroke rendered with [brush] — the brush picker tiles. */
    fun previewBitmap(brush: BrushType, widthPx: Int, heightPx: Int): Bitmap {
      val bitmap = Bitmap.createBitmap(widthPx, heightPx, Bitmap.Config.ARGB_8888)
      val w = widthPx.toFloat()
      val h = heightPx.toFloat()
      val points = (0..24).map { i ->
        val t = i / 24f
        PointF(w * (0.15f + 0.7f * t), h * (0.5f + 0.22f * sin(t * 2f * PI.toFloat())))
      }
      drawStroke(Canvas(bitmap), Stroke(points, Color.WHITE, h * 0.16f, brush, 12345), 1f)
      return bitmap
    }

    fun dragLength(points: List<PointF>): Float {
      if (points.isEmpty()) return 0f
      val a = points.first()
      val b = points.last()
      return hypot(b.x - a.x, b.y - a.y)
    }

    /** A shape's outline as polylines (closed ones repeat their first
     *  point), in canvas px, fitted to the drag from [a] to [b]. Same
     *  geometry as iOS's shapePolylines. */
    fun shapePolylines(shape: ShapeType, a: PointF, b: PointF, width: Float): List<List<PointF>> {
      val minX = minOf(a.x, b.x)
      val maxX = maxOf(a.x, b.x)
      val minY = minOf(a.y, b.y)
      val maxY = maxOf(a.y, b.y)
      val cx = (minX + maxX) / 2f
      val cy = (minY + maxY) / 2f
      val rx = (maxX - minX) / 2f
      val ry = (maxY - minY) / 2f
      fun closed(p: List<PointF>): List<PointF> = if (p.isEmpty()) p else p + p[0]
      val twoPi = 2f * PI.toFloat()
      return when (shape) {
        ShapeType.LINE -> listOf(listOf(a, b))
        ShapeType.ARROW -> {
          val length = hypot(b.x - a.x, b.y - a.y)
          val head = minOf(maxOf(width * 3f, length * 0.25f), length * 0.6f)
          val angle = kotlin.math.atan2(b.y - a.y, b.x - a.x)
          val h1 = PointF(b.x - head * cos(angle - 0.5f), b.y - head * sin(angle - 0.5f))
          val h2 = PointF(b.x - head * cos(angle + 0.5f), b.y - head * sin(angle + 0.5f))
          listOf(listOf(a, b), listOf(h1, b, h2))
        }
        ShapeType.RECTANGLE -> listOf(closed(listOf(PointF(minX, minY), PointF(maxX, minY), PointF(maxX, maxY), PointF(minX, maxY))))
        ShapeType.OVAL -> listOf(closed((0 until 72).map { i ->
          val t = i / 72f * twoPi
          PointF(cx + rx * cos(t), cy + ry * sin(t))
        }))
        ShapeType.TRIANGLE -> listOf(closed(listOf(PointF(cx, minY), PointF(maxX, maxY), PointF(minX, maxY))))
        ShapeType.STAR -> listOf(closed((0 until 10).map { i ->
          val r = if (i % 2 == 0) 1f else 0.45f
          val t = -PI.toFloat() / 2f + i * PI.toFloat() / 5f
          PointF(cx + rx * r * cos(t), cy + ry * r * sin(t))
        }))
        ShapeType.HEART -> listOf(closed((0 until 72).map { i ->
          // Classic heart curve, x ∈ [-16, 16], y ∈ [-17, 12] (y up), fitted.
          val t = i / 72f * twoPi
          val st = sin(t)
          val x = 16f * st * st * st
          val y = 13f * cos(t) - 5f * cos(2 * t) - 2f * cos(3 * t) - cos(4 * t)
          PointF(cx + rx * x / 16f, minY + (maxY - minY) * (12f - y) / 29f)
        }))
      }
    }

    /** A shape drawn with the pen — the Shape tool's tiles. */
    fun shapePreviewBitmap(shape: ShapeType, widthPx: Int, heightPx: Int, strokePx: Float): Bitmap {
      val bitmap = Bitmap.createBitmap(widthPx, heightPx, Bitmap.Config.ARGB_8888)
      val side = minOf(widthPx, heightPx) * 0.62f
      val a = PointF(widthPx / 2f - side / 2f, heightPx / 2f - side / 2f)
      val b = PointF(widthPx / 2f + side / 2f, heightPx / 2f + side / 2f)
      val points = if (shape == ShapeType.LINE || shape == ShapeType.ARROW) listOf(PointF(a.x, b.y), PointF(b.x, a.y)) else listOf(a, b)
      drawStroke(Canvas(bitmap), Stroke(points, Color.WHITE, strokePx, BrushType.PEN, 0, shape), 1f)
      return bitmap
    }

    /** Smoothed path through raw touch points ("quadratic-through-
     *  midpoints"). Same technique as iOS's buildSmoothedPath. */
    fun buildSmoothedPath(points: List<PointF>, scale: Float): Path {
      val path = Path()
      if (points.isEmpty()) return path
      path.moveTo(points[0].x * scale, points[0].y * scale)
      for (i in 1 until points.size) {
        val prev = points[i - 1]
        val curr = points[i]
        val midX = (prev.x + curr.x) / 2f * scale
        val midY = (prev.y + curr.y) / 2f * scale
        path.quadTo(prev.x * scale, prev.y * scale, midX, midY)
      }
      val last = points.last()
      path.lineTo(last.x * scale, last.y * scale)
      return path
    }
  }
}
