package com.intoactive.app.mediaeditor

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.icu.text.BreakIterator
import android.text.TextPaint
import android.widget.TextView
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

// Text layers are drawn by ONE renderer — on-screen preview, photo export
// and video export all call TextLayerRenderer.render, so what you see is
// exactly what gets exported. Line-by-line port of iOS's
// TextLayerRenderer.swift: same fonts (bundled, identical files), same font
// metrics table, same constants. Change both together.

enum class TextBackgroundMode { NONE, SOLID, TRANSLUCENT } // ordinal is saved

/** Same raw values as iOS's NSTextAlignment (left 0, center 1, right 2). */
enum class TextAlign(val raw: Int) {
  LEFT(0), CENTER(1), RIGHT(2);

  companion object {
    fun fromRaw(raw: Int): TextAlign = values().firstOrNull { it.raw == raw } ?: CENTER
  }
}

/** Every look setting of a text layer. Ranges: size 0.5–2 (1 = normal),
 *  outline/shadow 0–1, opacity 0–1, stretchX/Y 0.5–2, arch -1…1
 *  (positive bends like ∩, negative like ∪). */
data class TextLayerStyle(
  val fontId: String = TextFontCatalog.defaultOption.id,
  val color: Int = Color.WHITE,
  val isBold: Boolean = false,
  val isItalic: Boolean = false,
  val isUnderlined: Boolean = false,
  val alignment: TextAlign = TextAlign.CENTER,
  val background: TextBackgroundMode = TextBackgroundMode.NONE,
  val size: Float = 1f,
  val outline: Float = 0f,
  val shadow: Float = 0f,
  val opacity: Float = 1f,
  val stretchX: Float = 1f,
  val stretchY: Float = 1f,
  val arch: Float = 0f,
)

/** [fileName] is in assets/text_fonts/; null = DM Sans Bold (assets/fonts/).
 *  [ascent]/[descent] are the hhea values as a fraction of the em — used
 *  for line layout instead of each platform's own font metrics, so lines
 *  sit at exactly the same place on iOS and Android. */
data class TextFontOption(
  val id: String,
  val label: String,
  val fileName: String?,
  val sizeFactor: Float,
  val ascent: Float,
  val descent: Float,
)

object TextFontCatalog {
  const val BASE_SIZE = 28f // dp, same as iOS points

  // Ids are saved in re-edit projects — never rename one.
  val options = listOf(
    TextFontOption("classic", "Classic", null, 1.0f, 0.992f, 0.310f),
    TextFontOption("serif", "Serif", "Playfair", 1.0f, 1.082f, 0.251f),
    TextFontOption("script", "Script", "Pacifico", 0.9f, 1.303f, 0.453f),
    TextFontOption("headline", "Headline", "BebasNeue", 1.05f, 0.900f, 0.300f),
    TextFontOption("marker", "Marker", "PermanentMarker", 0.95f, 1.109f, 0.317f),
    TextFontOption("lobster", "Lobster", "Lobster", 1.0f, 1.000f, 0.250f),
    TextFontOption("impact", "Impact", "Anton", 0.9f, 1.176f, 0.329f),
    TextFontOption("handwritten", "Handwritten", "Caveat", 1.2f, 0.960f, 0.300f),
    TextFontOption("rounded", "Rounded", "Nunito", 1.0f, 1.011f, 0.353f),
    TextFontOption("comic", "Comic", "Bangers", 1.0f, 0.883f, 0.181f),
    TextFontOption("fancy", "Fancy", "GreatVibes", 1.3f, 0.851f, 0.401f),
    TextFontOption("elegant", "Elegant", "Raleway", 1.0f, 0.940f, 0.234f),
    TextFontOption("fashion", "Fashion", "AbrilFatface", 1.0f, 1.058f, 0.291f),
    TextFontOption("typewriter", "Typewriter", "SpecialElite", 1.25f, 0.703f, 0.297f),
    TextFontOption("playful", "Playful", "Chewy", 1.0f, 0.979f, 0.303f),
    TextFontOption("retro", "Retro", "Righteous", 1.0f, 0.985f, 0.257f),
    TextFontOption("condensed", "Condensed", "Oswald", 0.95f, 1.193f, 0.289f),
    TextFontOption("royal", "Royal", "Cinzel", 0.95f, 0.976f, 0.372f),
    TextFontOption("future", "Future", "Orbitron", 0.9f, 1.011f, 0.243f),
    TextFontOption("block", "Block", "Bungee", 0.85f, 1.020f, 0.300f),
    TextFontOption("dancing", "Dancing", "DancingScript", 1.15f, 0.920f, 0.280f),
    TextFontOption("mono", "Mono", "SpaceMono", 0.95f, 1.120f, 0.361f),
    TextFontOption("spooky", "Spooky", "Creepster", 1.0f, 0.951f, 0.218f),
  )

  val defaultOption: TextFontOption get() = options[0]

  fun option(id: String?): TextFontOption = options.firstOrNull { it.id == id } ?: defaultOption

  /** Maps the font labels older Android projects were saved with to the
   *  closest bundled font. */
  fun optionId(legacyLabel: String?): String = when (legacyLabel) {
    "Serif" -> "serif"
    "Mono" -> "mono"
    "Script" -> "script"
    "Condensed", "Condensed Light", "Condensed Medium" -> "condensed"
    "Casual" -> "handwritten"
    "Black" -> "impact"
    "Light", "Thin" -> "elegant"
    "Small Caps" -> "royal"
    "Serif Mono" -> "typewriter"
    else -> defaultOption.id
  }

  private val typefaces = HashMap<String, Typeface>()

  @Synchronized
  fun typeface(context: Context, option: TextFontOption): Typeface {
    typefaces[option.id]?.let { return it }
    val path = option.fileName?.let { "text_fonts/$it.ttf" } ?: "fonts/DMSans-Bold.ttf"
    val typeface = runCatching { Typeface.createFromAsset(context.assets, path) }.getOrDefault(Typeface.DEFAULT_BOLD)
    typefaces[option.id] = typeface
    return typeface
  }
}

object TextLayerRenderer {
  // Shared constants (× font size unless noted) — keep in sync with iOS.
  const val LINE_SPACING = 1.08f
  const val BACKGROUND_PAD_X = 0.32f
  const val BACKGROUND_PAD_Y = 0.14f
  const val BACKGROUND_RADIUS = 0.28f
  const val TRANSLUCENT_ALPHA = 0.55f
  const val OUTLINE_MAX_WIDTH = 0.22f
  const val BOLD_WIDTH = 0.045f
  const val ITALIC_SKEW = 0.22f
  const val UNDERLINE_OFFSET = 0.12f
  const val UNDERLINE_THICKNESS = 0.07f
  const val SHADOW_MAX_BLUR = 0.18f
  const val SHADOW_MAX_OFFSET = 0.08f
  const val MAX_ARCH_ANGLE = 1.6f * Math.PI.toFloat()

  class Rendered(val bitmap: Bitmap, val width: Float, val height: Float)

  /** One drawn run of text: a whole line, or a single character when
   *  arched. (x, y) is the baseline centre; the run is drawn from
   *  x = -width/2 in a frame rotated by [rotation] radians. */
  private class Piece(val text: String, val x: Float, val y: Float, val rotation: Float, val width: Float)

  private sealed class BackgroundPiece {
    class Rect(val rect: RectF, val radius: Float) : BackgroundPiece()
    class Arc(val cx: Float, val cy: Float, val radius: Float, val start: Float, val end: Float, val thickness: Float) : BackgroundPiece()
  }

  private class Layout(
    val paint: TextPaint,
    val fontSize: Float,
    val ascent: Float,
    val descent: Float,
  ) {
    val pieces = mutableListOf<Piece>()
    val backgrounds = mutableListOf<BackgroundPiece>()
    var bounds = RectF()
  }

  /** On-screen size in px for [scale] = px per dp (display density). */
  fun measure(context: Context, text: String, style: TextLayerStyle, scale: Float): Pair<Float, Float> {
    val layout = makeLayout(context, text, style, scale)
    return outputSize(layout, style)
  }

  /** Renders at [scale] px per dp. width/height are the exact, unrounded
   *  draw size — the bitmap is that rounded up. */
  fun render(context: Context, text: String, style: TextLayerStyle, scale: Float): Rendered? {
    val layout = makeLayout(context, text, style, scale)
    val (width, height) = outputSize(layout, style)
    val pixelWidth = ceil(width).toInt()
    val pixelHeight = ceil(height).toInt()
    if (pixelWidth <= 0 || pixelHeight <= 0 || pixelWidth.toLong() * pixelHeight > 60_000_000L) return null
    val contentWidth = layout.bounds.width() * style.stretchX
    val contentHeight = layout.bounds.height() * style.stretchY

    // Content first (no shadow, full opacity), then composited with its
    // shadow at the layer's opacity.
    val content = Bitmap.createBitmap(pixelWidth, pixelHeight, Bitmap.Config.ARGB_8888)
    Canvas(content).apply {
      translate((pixelWidth - contentWidth) / 2f, (pixelHeight - contentHeight) / 2f)
      scale(style.stretchX, style.stretchY)
      translate(-layout.bounds.left, -layout.bounds.top)
      drawContent(this, layout, style)
    }
    val shadow = if (style.shadow > 0.001f) makeShadow(content, style, layout.fontSize) else null

    val result = Bitmap.createBitmap(pixelWidth, pixelHeight, Bitmap.Config.ARGB_8888)
    Canvas(result).apply {
      val alpha = (style.opacity.coerceIn(0f, 1f) * 255).roundToInt()
      saveLayerAlpha(0f, 0f, pixelWidth.toFloat(), pixelHeight.toFloat(), alpha)
      shadow?.let { drawBitmap(it, 0f, 0f, null) }
      drawBitmap(content, 0f, 0f, null)
      restore()
    }
    content.recycle()
    shadow?.recycle()
    return Rendered(result, width, height)
  }

  // ── Layout ──────────────────────────────────────────────────────────

  private fun outputSize(layout: Layout, style: TextLayerStyle): Pair<Float, Float> {
    val pad = shadowPadding(style, layout.fontSize)
    return Pair(
      max(layout.bounds.width() * style.stretchX + pad * 2, 1f),
      max(layout.bounds.height() * style.stretchY + pad * 2, 1f),
    )
  }

  private fun shadowBlur(style: TextLayerStyle, fontSize: Float) = SHADOW_MAX_BLUR * fontSize * style.shadow

  private fun shadowOffset(style: TextLayerStyle, fontSize: Float) = SHADOW_MAX_OFFSET * fontSize * style.shadow

  private fun shadowPadding(style: TextLayerStyle, fontSize: Float): Float {
    if (style.shadow <= 0.001f) return 0f
    return ceil(shadowBlur(style, fontSize) * 2.5f + shadowOffset(style, fontSize))
  }

  /** Centre x and advance of every character, from the shaped line, so
   *  kerning is kept when the characters are placed one by one on an arc. */
  private fun characterRuns(text: String, paint: TextPaint): List<Triple<String, Float, Float>> {
    val iterator = BreakIterator.getCharacterInstance()
    iterator.setText(text)
    val result = mutableListOf<Triple<String, Float, Float>>()
    var start = iterator.first()
    var end = iterator.next()
    while (end != BreakIterator.DONE) {
      val x0 = paint.getRunAdvance(text, 0, text.length, 0, text.length, false, start)
      val x1 = paint.getRunAdvance(text, 0, text.length, 0, text.length, false, end)
      val width = max(x1 - x0, 0f)
      result.add(Triple(text.substring(start, end), x0 + width / 2f, width))
      start = end
      end = iterator.next()
    }
    return result
  }

  private fun makeLayout(context: Context, text: String, style: TextLayerStyle, scale: Float): Layout {
    val option = TextFontCatalog.option(style.fontId)
    val fontSize = TextFontCatalog.BASE_SIZE * option.sizeFactor * style.size.coerceIn(0.3f, 3f) * scale
    val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
      typeface = TextFontCatalog.typeface(context, option)
      textSize = fontSize
      textAlign = Paint.Align.LEFT
    }
    val ascent = option.ascent * fontSize
    val descent = option.descent * fontSize
    val lineHeight = (ascent + descent) * LINE_SPACING
    val layout = Layout(paint, fontSize, ascent, descent)

    val lines = text.replace("\r\n", "\n").split("\n")
    val widths = lines.map { if (it.isEmpty()) 0f else paint.measureText(it) }
    val blockWidth = max(widths.maxOrNull() ?: 0f, 1f)
    val hasBackground = style.background != TextBackgroundMode.NONE
    val padX = if (hasBackground) BACKGROUND_PAD_X * fontSize else 0f
    val padY = if (hasBackground) BACKGROUND_PAD_Y * fontSize else 0f

    fun lineX(width: Float): Float = when (style.alignment) {
      TextAlign.LEFT -> 0f
      TextAlign.RIGHT -> blockWidth - width
      TextAlign.CENTER -> (blockWidth - width) / 2f
    }

    val points = mutableListOf<Float>() // x, y pairs
    /** A box given in piece-local coordinates (origin = baseline centre),
     *  rotated and moved into place. [skew] applies the italic slant. */
    fun addBox(cx: Float, cy: Float, rotation: Float, left: Float, right: Float, top: Float, bottom: Float, skew: Boolean = false) {
      val c = cos(rotation)
      val s = sin(rotation)
      for ((x0, y) in listOf(left to top, right to top, left to bottom, right to bottom)) {
        val x = if (skew) x0 - ITALIC_SKEW * y else x0
        points.add(cx + x * c - y * s)
        points.add(cy + x * s + y * c)
      }
    }
    fun addBox(cx: Float, cy: Float, rotation: Float, halfWidth: Float, top: Float, bottom: Float) =
      addBox(cx, cy, rotation, -halfWidth, halfWidth, top, bottom)
    /** The visible letters of [text] (not the font's full line box), so the
     *  layer's box hugs the text and it can be moved right to the edges.
     *  Same as iOS's addInk. */
    val inkRect = android.graphics.Rect()
    fun addInk(text: String, cx: Float, cy: Float, rotation: Float, width: Float) {
      paint.getTextBounds(text, 0, text.length, inkRect)
      if (inkRect.isEmpty) {
        addBox(cx, cy, rotation, -width / 2f, width / 2f, -ascent, descent, style.isItalic)
      } else {
        addBox(cx, cy, rotation, -width / 2f + inkRect.left, -width / 2f + inkRect.right, inkRect.top.toFloat(), inkRect.bottom.toFloat(), style.isItalic)
      }
      if (style.isUnderlined) {
        addBox(cx, cy, rotation, -width / 2f, width / 2f,
          (UNDERLINE_OFFSET - UNDERLINE_THICKNESS / 2f) * fontSize, (UNDERLINE_OFFSET + UNDERLINE_THICKNESS / 2f) * fontSize)
      }
    }

    val arch = style.arch.coerceIn(-1f, 1f)
    if (abs(arch) < 0.01f) {
      lines.forEachIndexed { index, line ->
        if (line.isEmpty()) return@forEachIndexed
        val width = widths[index]
        val x = lineX(width)
        val baseline = ascent + index * lineHeight
        layout.pieces.add(Piece(line, x + width / 2f, baseline, 0f, width))
        addInk(line, x + width / 2f, baseline, 0f, width)
        if (hasBackground) {
          val rect = RectF(x - padX, baseline - ascent - padY, x + width + padX, baseline + descent + padY)
          layout.backgrounds.add(BackgroundPiece.Rect(rect, min(BACKGROUND_RADIUS * fontSize, rect.height() / 2f)))
          addBox(rect.centerX(), rect.centerY(), 0f, rect.width() / 2f, -rect.height() / 2f, rect.height() / 2f)
        }
      }
    } else {
      val angle = arch * MAX_ARCH_ANGLE
      val baseRadius = blockWidth / abs(angle)
      val bendsUp = arch > 0f
      val centerX = blockWidth / 2f
      val centerY = if (bendsUp) ascent + baseRadius else ascent - baseRadius
      lines.forEachIndexed { index, line ->
        if (line.isEmpty()) return@forEachIndexed
        val offset = index * lineHeight
        val radius = max(if (bendsUp) baseRadius - offset else baseRadius + offset, lineHeight * 0.5f)
        val x = lineX(widths[index])
        // Returns x, y, rotation.
        fun position(arcLength: Float, r: Float): Triple<Float, Float, Float> {
          val phi = arcLength / radius
          return if (bendsUp) {
            Triple(centerX + r * sin(phi), centerY - r * cos(phi), phi)
          } else {
            Triple(centerX + r * sin(phi), centerY + r * cos(phi), -phi)
          }
        }
        for ((character, center, width) in characterRuns(line, paint)) {
          val (px, py, rotation) = position(x + center - blockWidth / 2f, radius)
          layout.pieces.add(Piece(character, px, py, rotation, width))
          addInk(character, px, py, rotation, width)
        }
        if (hasBackground) {
          val thickness = ascent + descent + padY * 2
          val midRadius = if (bendsUp) radius + (ascent - descent) / 2f else radius - (ascent - descent) / 2f
          var startLength = x - padX - blockWidth / 2f + thickness / 2f
          var endLength = x + widths[index] + padX - blockWidth / 2f - thickness / 2f
          if (endLength < startLength) {
            val mid = (startLength + endLength) / 2f
            startLength = mid
            endLength = mid
          }
          val startPhi = startLength / radius
          val endPhi = endLength / radius
          // Arc angles in the y-down frame: point = center + r·(cos α, sin α).
          val halfPi = (Math.PI / 2).toFloat()
          val startAngle = if (bendsUp) startPhi - halfPi else halfPi - startPhi
          val endAngle = if (bendsUp) endPhi - halfPi else halfPi - endPhi
          layout.backgrounds.add(BackgroundPiece.Arc(centerX, centerY, max(midRadius, 1f), startAngle, endAngle, thickness))
          for (step in 0..24) {
            val t = step / 24f
            val arcLength = (startLength - thickness / 2f) + (endLength - startLength + thickness) * t
            for (r in listOf(midRadius - thickness / 2f, midRadius + thickness / 2f)) {
              val (px, py, _) = position(arcLength, max(r, 0f))
              points.add(px)
              points.add(py)
            }
          }
        }
      }
    }

    if (points.isEmpty()) {
      layout.bounds = RectF(0f, 0f, 1f, ascent + descent)
      return layout
    }
    var minX = Float.MAX_VALUE
    var minY = Float.MAX_VALUE
    var maxX = -Float.MAX_VALUE
    var maxY = -Float.MAX_VALUE
    for (i in points.indices step 2) {
      minX = min(minX, points[i]); maxX = max(maxX, points[i])
      minY = min(minY, points[i + 1]); maxY = max(maxY, points[i + 1])
    }
    val strokePad = (if (style.outline > 0.001f) OUTLINE_MAX_WIDTH * fontSize * style.outline / 2f else 0f) +
      (if (style.isBold) BOLD_WIDTH * fontSize / 2f else 0f)
    // Ink bounds already cover overhangs and the italic slant.
    val pad = strokePad + 1f
    layout.bounds = RectF(minX - pad, minY - pad, maxX + pad, maxY + pad)
    return layout
  }

  // ── Drawing ─────────────────────────────────────────────────────────

  private fun luminance(color: Int): Float =
    (0.299f * Color.red(color) + 0.587f * Color.green(color) + 0.114f * Color.blue(color)) / 255f

  /** Text colour actually drawn: on a background the chosen colour fills
   *  the background and the text turns black or white to stay readable. */
  fun fillColor(style: TextLayerStyle): Int {
    if (style.background == TextBackgroundMode.NONE) return style.color
    return if (luminance(style.color) > 0.6f) Color.BLACK else Color.WHITE
  }

  private fun drawContent(canvas: Canvas, layout: Layout, style: TextLayerStyle) {
    val fontSize = layout.fontSize
    val fill = fillColor(style)

    if (style.background != TextBackgroundMode.NONE) {
      val alpha = if (style.background == TextBackgroundMode.TRANSLUCENT) TRANSLUCENT_ALPHA else 1f
      // One layer so overlapping line pills don't double up their alpha
      // where they touch.
      canvas.saveLayerAlpha(null, (alpha * 255).roundToInt())
      val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = style.color or 0xFF000000.toInt() }
      for (piece in layout.backgrounds) {
        when (piece) {
          is BackgroundPiece.Rect -> {
            paint.style = Paint.Style.FILL
            canvas.drawRoundRect(piece.rect, piece.radius, piece.radius, paint)
          }
          is BackgroundPiece.Arc -> {
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = piece.thickness
            paint.strokeCap = Paint.Cap.ROUND
            val oval = RectF(piece.cx - piece.radius, piece.cy - piece.radius, piece.cx + piece.radius, piece.cy + piece.radius)
            val startDegrees = Math.toDegrees(piece.start.toDouble()).toFloat()
            val sweepDegrees = Math.toDegrees((piece.end - piece.start).toDouble()).toFloat()
            canvas.drawArc(oval, startDegrees, sweepDegrees, false, paint)
          }
        }
      }
      canvas.restore()
    }

    val boldStroke = if (style.isBold) BOLD_WIDTH * fontSize else 0f
    if (style.outline > 0.001f) {
      val outlineColor = if (luminance(fill) > 0.5f) Color.BLACK else Color.WHITE
      drawPieces(canvas, layout, style, outlineColor, OUTLINE_MAX_WIDTH * fontSize * style.outline + boldStroke, strokeOnly = true)
    }
    drawPieces(canvas, layout, style, fill, boldStroke, strokeOnly = false)
  }

  private fun drawPieces(
    canvas: Canvas,
    layout: Layout,
    style: TextLayerStyle,
    color: Int,
    strokeWidth: Float,
    strokeOnly: Boolean,
  ) {
    val fontSize = layout.fontSize
    val paint = TextPaint(layout.paint).apply {
      this.color = color
      this.style = when {
        strokeOnly -> Paint.Style.STROKE
        strokeWidth > 0f -> Paint.Style.FILL_AND_STROKE
        else -> Paint.Style.FILL
      }
      this.strokeWidth = strokeWidth
      strokeJoin = Paint.Join.ROUND
      textSkewX = if (style.isItalic) -ITALIC_SKEW else 0f
    }
    val underlinePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
    for (piece in layout.pieces) {
      canvas.save()
      canvas.translate(piece.x, piece.y)
      canvas.rotate(Math.toDegrees(piece.rotation.toDouble()).toFloat())
      if (style.isUnderlined) {
        val grow = if (strokeOnly) strokeWidth / 2f else 0f
        val top = UNDERLINE_OFFSET * fontSize - UNDERLINE_THICKNESS * fontSize / 2f - grow
        canvas.drawRect(
          -piece.width / 2f - grow, top,
          piece.width / 2f + grow, top + UNDERLINE_THICKNESS * fontSize + grow * 2,
          underlinePaint,
        )
      }
      canvas.drawText(piece.text, -piece.width / 2f, 0f, paint)
      canvas.restore()
    }
  }

  // ── Shadow ──────────────────────────────────────────────────────────

  private fun makeShadow(content: Bitmap, style: TextLayerStyle, fontSize: Float): Bitmap {
    val blur = shadowBlur(style, fontSize)
    val offset = shadowOffset(style, fontSize)
    val alpha = 0.3f + 0.5f * style.shadow.coerceIn(0f, 1f)
    val mask = content.extractAlpha()
    val shadow = Bitmap.createBitmap(content.width, content.height, Bitmap.Config.ARGB_8888)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
      color = Color.argb((alpha * 255).roundToInt(), 0, 0, 0)
      if (blur > 0.5f) maskFilter = BlurMaskFilter(blur, BlurMaskFilter.Blur.NORMAL)
    }
    Canvas(shadow).drawBitmap(mask, 0f, offset, paint)
    mask.recycle()
    return shadow
  }
}

/** A text layer drawn by TextLayerRenderer (not TextView's own text
 *  drawing), so fonts, outline, shadow, background, stretch and arch look
 *  identical on screen and in the exported file. `text` is still set so
 *  everything that reads a layer's string keeps working. */
class StyledTextLayerView(context: Context) : TextView(context) {
  var layerStyle: TextLayerStyle = TextLayerStyle()
    private set
  private var rendered: Bitmap? = null
  private var renderedScale = 0f
  private val bitmapPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)

  fun applyText(text: String, style: TextLayerStyle) {
    layerStyle = style
    this.text = text
    rendered = null
    requestLayout()
    invalidate()
  }

  private val density get() = resources.displayMetrics.density

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    val (width, height) = TextLayerRenderer.measure(context, text?.toString().orEmpty(), layerStyle, density)
    setMeasuredDimension(ceil(width).toInt(), ceil(height).toInt())
  }

  /** Renders sharper while the layer is pinched bigger (the view's scale
   *  stretches the drawn bitmap), capped so a huge layer can't allocate a
   *  huge bitmap. */
  private fun desiredScale(): Float {
    val zoom = abs(scaleX).coerceIn(1f, 4f)
    var scale = (density * zoom * 2f).roundToInt() / 2f
    val dpWidth = width / density
    val dpHeight = height / density
    val maxPixels = 12_000_000f
    if (dpWidth * dpHeight * scale * scale > maxPixels) {
      scale = max(density, sqrt(maxPixels / max(dpWidth * dpHeight, 1f)))
    }
    return scale
  }

  override fun setScaleX(scaleX: Float) {
    super.setScaleX(scaleX)
    if (rendered != null && abs(desiredScale() - renderedScale) > 0.01f) invalidate()
  }

  override fun onDraw(canvas: Canvas) {
    val scale = desiredScale()
    if (rendered == null || abs(scale - renderedScale) > 0.01f) {
      // The old bitmap is dropped, not recycled — the render thread may
      // still be drawing it.
      rendered = TextLayerRenderer.render(context, text?.toString().orEmpty(), layerStyle, scale)?.bitmap
      renderedScale = scale
    }
    val bitmap = rendered ?: return
    val drawWidth = bitmap.width * density / scale
    val drawHeight = bitmap.height * density / scale
    val left = (width - drawWidth) / 2f
    val top = (height - drawHeight) / 2f
    canvas.drawBitmap(bitmap, null, RectF(left, top, left + drawWidth, top + drawHeight), bitmapPaint)
  }
}
