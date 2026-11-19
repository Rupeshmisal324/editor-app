package com.intoactive.app.mediaeditor

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffColorFilter
import android.graphics.RectF
import android.util.LruCache
import org.json.JSONObject
import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

// Sticker library + sticker look (opacity / flip / outline / shadow).
// Line-by-line port of iOS's StickerKit.swift — change both together.

/** The bundled sticker library: categories and search words from
 *  assets/sticker_catalog.json (same file on iOS). Sticker images are
 *  drawable-nodpi resources named "sticker_<hex>". */
object StickerCatalog {
  class Category(val title: String, val stickers: List<String>)

  @Volatile private var loaded: Pair<List<Category>, Map<String, String>>? = null

  private fun load(context: Context): Pair<List<Category>, Map<String, String>> {
    loaded?.let { return it }
    val result = runCatching {
      val json = JSONObject(context.assets.open("sticker_catalog.json").bufferedReader().use { it.readText() })
      val categories = json.getJSONArray("categories").let { array ->
        (0 until array.length()).map { i ->
          val entry = array.getJSONObject(i)
          val names = entry.getJSONArray("stickers")
          Category(entry.getString("title"), (0 until names.length()).map { names.getString(it) })
        }
      }
      val keywordsJson = json.getJSONObject("keywords")
      val keywords = keywordsJson.keys().asSequence().associateWith { keywordsJson.getString(it) }
      categories to keywords
    }.getOrDefault(emptyList<Category>() to emptyMap())
    loaded = result
    return result
  }

  fun categories(context: Context): List<Category> = load(context).first

  /** Every sticker once, in category order. */
  fun allStickers(context: Context): List<String> = categories(context).flatMap { it.stickers }.distinct()

  /** Stickers whose name contains every typed word ("red heart", "dog"). */
  fun search(context: Context, query: String): List<String> {
    val words = query.lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
    if (words.isEmpty()) return emptyList()
    val keywords = load(context).second
    return allStickers(context).filter { name ->
      val keyword = keywords[name].orEmpty()
      words.all { keyword.contains(it) }
    }
  }

  /** Full-size sticker artwork. */
  fun bitmap(context: Context, name: String): Bitmap? {
    val resId = context.resources.getIdentifier(name, "drawable", context.packageName)
    if (resId == 0) return null
    return BitmapFactory.decodeResource(context.resources, resId)
  }

  private val thumbnailCache = object : LruCache<String, Bitmap>(16 * 1024 * 1024) {
    override fun sizeOf(key: String, value: Bitmap) = value.byteCount
  }

  /** Small decoded copy for the picker grid — hundreds of full-size
   *  images would cost tens of MB. */
  fun thumbnail(context: Context, name: String, sidePx: Int): Bitmap? {
    val key = "$name@$sidePx"
    thumbnailCache.get(key)?.let { return it }
    val full = bitmap(context, name) ?: return null
    val thumb = Bitmap.createScaledBitmap(full, sidePx, sidePx, true)
    if (thumb !== full) full.recycle()
    thumbnailCache.put(key, thumb)
    return thumb
  }
}

/** Look settings of a sticker layer. outline/shadow 0–1, opacity 0–1. */
data class StickerStyle(
  val opacity: Float = 1f,
  val flipX: Boolean = false,
  val flipY: Boolean = false,
  val outline: Float = 0f,
  val shadow: Float = 0f,
) {
  val isDefault: Boolean get() = this == StickerStyle()
}

object StickerStyleRenderer {
  // × the sticker's side — keep in sync with iOS.
  const val OUTLINE_MAX_WIDTH = 0.08f
  const val SHADOW_MAX_BLUR = 0.06f
  const val SHADOW_MAX_OFFSET = 0.04f

  /** Extra room around the sticker for its outline and shadow (same units
   *  as [side]) — the layer grows by this on every side. */
  fun padding(style: StickerStyle, side: Float): Float {
    var pad = OUTLINE_MAX_WIDTH * side * style.outline
    if (style.shadow > 0.001f) {
      pad += SHADOW_MAX_BLUR * side * style.shadow * 2.5f + SHADOW_MAX_OFFSET * side * style.shadow
    }
    return ceil(pad)
  }

  /** The styled sticker for a [side]-sized (px) square sticker. Its logical
   *  size is side + 2·padding; the bitmap holds [pixelScale] pixels per
   *  logical px (preview renders sharper than the view; export uses 1). */
  fun render(base: Bitmap, side: Float, style: StickerStyle, pixelScale: Float): Pair<Bitmap, Float> {
    val pad = padding(style, side)
    val outSide = side + pad * 2
    val pixels = ceil(outSide * pixelScale).toInt().coerceAtLeast(1)
    val art = RectF(pad * pixelScale, pad * pixelScale, (pad + side) * pixelScale, (pad + side) * pixelScale)

    // Sticker (flipped) + white outline, no shadow, full opacity.
    val content = Bitmap.createBitmap(pixels, pixels, Bitmap.Config.ARGB_8888)
    Canvas(content).apply {
      scale(if (style.flipX) -1f else 1f, if (style.flipY) -1f else 1f, art.centerX(), art.centerY())
      val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
      if (style.outline > 0.001f) {
        // Dilate: the white silhouette stamped around a circle (two rings
        // so thick outlines stay solid).
        val silhouettePaint = Paint(paint).apply { colorFilter = PorterDuffColorFilter(Color.WHITE, PorterDuff.Mode.SRC_IN) }
        val radius = OUTLINE_MAX_WIDTH * side * style.outline * pixelScale
        for (ring in listOf(radius, radius * 0.5f)) {
          for (step in 0 until 24) {
            val angle = step / 24f * 2f * PI.toFloat()
            val rect = RectF(art).apply { offset(ring * cos(angle), ring * sin(angle)) }
            drawBitmap(base, null, rect, silhouettePaint)
          }
        }
      }
      drawBitmap(base, null, art, paint)
    }

    val result = Bitmap.createBitmap(pixels, pixels, Bitmap.Config.ARGB_8888)
    Canvas(result).apply {
      saveLayerAlpha(0f, 0f, pixels.toFloat(), pixels.toFloat(), (style.opacity.coerceIn(0f, 1f) * 255).roundToInt())
      if (style.shadow > 0.001f) {
        // Same recipe as TextLayerRenderer's shadow (black, blurred, down).
        val blur = SHADOW_MAX_BLUR * side * style.shadow * pixelScale
        val offset = SHADOW_MAX_OFFSET * side * style.shadow * pixelScale
        val alpha = 0.3f + 0.5f * style.shadow.coerceIn(0f, 1f)
        val mask = content.extractAlpha()
        val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
          color = Color.argb((alpha * 255).roundToInt(), 0, 0, 0)
          if (blur > 0.5f) maskFilter = BlurMaskFilter(blur, BlurMaskFilter.Blur.NORMAL)
        }
        drawBitmap(mask, 0f, offset, shadowPaint)
        mask.recycle()
      }
      drawBitmap(content, 0f, 0f, null)
      restore()
    }
    content.recycle()
    return result to outSide
  }
}
