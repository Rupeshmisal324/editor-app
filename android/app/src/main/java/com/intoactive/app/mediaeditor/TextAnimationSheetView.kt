package com.intoactive.app.mediaeditor

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.SystemClock
import android.util.TypedValue
import android.view.Choreographer
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView

/**
 * CapCut-style text animation sheet (same design as iOS
 * TextAnimationSheetView): ✕ · Animation · ✓, In / Out / Loop tabs, a grid
 * of named tiles (each with a small "Aa" playing its own animation) and a
 * duration slider for the open tab. Every change is reported through
 * [onChange] so the video can preview it live; the caller applies /
 * reverts on close.
 */
@SuppressLint("ViewConstructor")
internal class TextAnimationSheetView(
  context: Context,
  initial: TextAnimConfig,
  bottomInsetPx: Int,
) : LinearLayout(context) {
  var onChange: ((TextAnimConfig, Int) -> Unit)? = null
  var onClose: ((Boolean) -> Unit)? = null
  var config: TextAnimConfig = initial
    private set

  private val density = resources.displayMetrics.density
  private fun px(dp: Float) = (dp * density).toInt()
  private var tab = when {
    initial.inType != 0 || (initial.outType == 0 && initial.loopType == 0) -> 0
    initial.outType != 0 -> 1
    else -> 2
  }
  private val tabLabels = ArrayList<TextView>()
  private val tabDots = ArrayList<View>()
  private val tabUnderlines = ArrayList<View>()
  private val grid = LinearLayout(context).apply { orientation = VERTICAL }
  private val tiles = ArrayList<Tile>()
  private val sliderTitle = TextView(context)
  private val sliderValue = TextView(context)
  private val slider = SeekBar(context)
  private val sliderRow = LinearLayout(context)
  private val startMs = SystemClock.uptimeMillis()
  private var ticking = false
  private val frameCallback = object : Choreographer.FrameCallback {
    override fun doFrame(frameTimeNanos: Long) {
      if (!ticking) return
      tiles.forEach { it.invalidate() }
      Choreographer.getInstance().postFrameCallback(this)
    }
  }

  init {
    orientation = VERTICAL
    isClickable = true
    setPadding(px(12f), px(8f), px(12f), px(8f) + bottomInsetPx)
    background = GradientDrawable().apply {
      val r = 22f * density
      cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
      setColor(EditorDesignTokens.Colors.panelBackground)
    }
    addView(header(), LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
    addView(tabsRow(), LayoutParams(LayoutParams.MATCH_PARENT, px(40f)))
    addView(View(context).apply { setBackgroundColor(EditorDesignTokens.Colors.divider) }, LayoutParams(LayoutParams.MATCH_PARENT, px(1f)))
    // Two rows, plus a peek of the third so it's clear the grid scrolls.
    addView(ScrollView(context).apply {
      isVerticalScrollBarEnabled = false
      addView(grid, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }, LayoutParams(LayoutParams.MATCH_PARENT, px(196f)).apply { topMargin = px(10f) })
    addView(sliderRow(), LayoutParams(LayoutParams.MATCH_PARENT, px(44f)).apply { topMargin = px(8f) })
    selectTab(tab, notify = false)
  }

  private fun header() = LinearLayout(context).apply {
    orientation = HORIZONTAL
    gravity = Gravity.CENTER_VERTICAL
    fun barButton(icon: EditorIcon, tint: Int, label: String, onClick: () -> Unit) = FrameLayout(context).apply {
      addView(EditorIconView(context, icon).apply { iconTint = tint }, FrameLayout.LayoutParams(px(22f), px(22f), Gravity.CENTER))
      contentDescription = label
      setOnClickListener {
        it.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        onClick()
      }
    }
    addView(barButton(EditorIcon.CLOSE, EditorDesignTokens.Colors.textPrimary, "Cancel") { onClose?.invoke(false) }, LayoutParams(px(44f), px(44f)))
    addView(TextView(context).apply {
      text = "Animation"
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
      typeface = Typeface.DEFAULT_BOLD
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      gravity = Gravity.CENTER
    }, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
    addView(barButton(EditorIcon.CHECK, EditorDesignTokens.Colors.accent, "Apply animation") { onClose?.invoke(true) }, LayoutParams(px(44f), px(44f)))
  }

  private fun tabsRow() = LinearLayout(context).apply {
    orientation = HORIZONTAL
    listOf("In", "Out", "Loop").forEachIndexed { i, name ->
      val label = TextView(context).apply {
        text = name
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        typeface = Typeface.DEFAULT_BOLD
        gravity = Gravity.CENTER
      }
      val dot = View(context).apply {
        background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(EditorDesignTokens.Colors.selectedToolTint) }
      }
      val underline = View(context).apply {
        background = GradientDrawable().apply { cornerRadius = density; setColor(EditorDesignTokens.Colors.textPrimary) }
      }
      val cell = FrameLayout(context).apply {
        addView(label, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT, Gravity.CENTER))
        addView(dot, FrameLayout.LayoutParams(px(5f), px(5f), Gravity.CENTER).apply { leftMargin = px(if (name == "Loop") 22f else if (name == "Out") 18f else 12f); topMargin = -px(8f) })
        addView(underline, FrameLayout.LayoutParams(px(28f), px(2f), Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply { bottomMargin = px(1f) })
        contentDescription = "$name animation"
        setOnClickListener {
          it.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
          selectTab(i)
        }
      }
      tabLabels += label
      tabDots += dot
      tabUnderlines += underline
      addView(cell, LayoutParams(0, LayoutParams.MATCH_PARENT, 1f))
    }
  }

  private fun sliderRow() = sliderRow.apply {
    orientation = HORIZONTAL
    gravity = Gravity.CENTER_VERTICAL
    setPadding(px(6f), 0, px(6f), 0)
    sliderTitle.apply {
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      setTextColor(EditorDesignTokens.Colors.textSecondary)
    }
    sliderValue.apply {
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      fontFeatureSettings = "tnum"
      setTextColor(EditorDesignTokens.Colors.textPrimary)
      gravity = Gravity.END or Gravity.CENTER_VERTICAL
    }
    slider.apply {
      progressTintList = ColorStateList.valueOf(EditorDesignTokens.Colors.textPrimary)
      thumbTintList = ColorStateList.valueOf(EditorDesignTokens.Colors.textPrimary)
      progressBackgroundTintList = ColorStateList.valueOf(EditorDesignTokens.Colors.divider)
      setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
        override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
          if (!fromUser) return
          val ms = range().first + progress * 100L
          config = when (tab) {
            0 -> config.copy(inDurationMs = ms)
            1 -> config.copy(outDurationMs = ms)
            else -> config.copy(loopPeriodMs = ms)
          }
          updateSliderLabel()
        }
        override fun onStartTrackingTouch(seekBar: SeekBar) {}
        override fun onStopTrackingTouch(seekBar: SeekBar) { onChange?.invoke(config, tab) }
      })
    }
    addView(sliderTitle, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
    addView(slider, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
    addView(sliderValue, LayoutParams(px(40f), LayoutParams.WRAP_CONTENT))
  }

  private fun titles() = when (tab) {
    0 -> TextAnimation.inTitles
    1 -> TextAnimation.outTitles
    else -> TextAnimation.loopTitles
  }

  private fun currentType() = when (tab) {
    0 -> config.inType
    1 -> config.outType
    else -> config.loopType
  }

  private fun range() = if (tab == 2) TextAnimation.LOOP_PERIOD_RANGE_MS else TextAnimation.DURATION_RANGE_MS

  private fun selectTab(index: Int, notify: Boolean = true) {
    tab = index
    tabLabels.forEachIndexed { i, label ->
      label.setTextColor(if (i == index) EditorDesignTokens.Colors.textPrimary else EditorDesignTokens.Colors.textSecondary)
    }
    tabUnderlines.forEachIndexed { i, v -> v.visibility = if (i == index) View.VISIBLE else View.INVISIBLE }
    grid.removeAllViews()
    tiles.clear()
    val columns = 4
    val names = titles()
    names.indices.chunked(columns).forEachIndexed { rowIndex, types ->
      val row = LinearLayout(context).apply { orientation = HORIZONTAL }
      for (c in 0 until columns) {
        val type = types.getOrNull(c)
        val lp = LayoutParams(0, px(86f), 1f).apply { if (c > 0) leftMargin = px(8f) }
        if (type == null) {
          row.addView(View(context), lp)
          continue
        }
        val tile = Tile(type, names[type]).apply {
          setOnClickListener {
            it.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
            pick(type)
          }
        }
        tiles += tile
        row.addView(tile, lp)
      }
      grid.addView(row, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { if (rowIndex > 0) topMargin = px(8f) })
    }
    (grid.parent as? ScrollView)?.scrollTo(0, 0)
    refreshSelection()
    if (notify && currentType() != 0) onChange?.invoke(config, tab)
  }

  private fun pick(type: Int) {
    config = when (tab) {
      0 -> config.copy(inType = type)
      1 -> config.copy(outType = type)
      else -> config.copy(loopType = type)
    }
    refreshSelection()
    onChange?.invoke(config, tab)
  }

  private fun refreshSelection() {
    val type = currentType()
    tiles.forEach { it.selectedTile = it.type == type; it.invalidate() }
    tabDots.forEachIndexed { i, dot ->
      dot.visibility = if (listOf(config.inType, config.outType, config.loopType)[i] != 0) View.VISIBLE else View.INVISIBLE
    }
    val r = range()
    slider.max = ((r.last - r.first) / 100).toInt()
    val ms = when (tab) {
      0 -> config.inDurationMs
      1 -> config.outDurationMs
      else -> config.loopPeriodMs
    }
    slider.progress = ((ms - r.first) / 100).toInt()
    sliderTitle.text = if (tab == 2) "Cycle" else "Duration"
    val enabled = type != 0
    slider.isEnabled = enabled
    sliderRow.alpha = if (enabled) 1f else 0.4f
    updateSliderLabel()
  }

  private fun updateSliderLabel() {
    val ms = range().first + slider.progress * 100L
    sliderValue.text = String.format(java.util.Locale.US, "%.1fs", ms / 1000f)
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    ticking = true
    Choreographer.getInstance().postFrameCallback(frameCallback)
  }

  override fun onDetachedFromWindow() {
    ticking = false
    Choreographer.getInstance().removeFrameCallback(frameCallback)
    super.onDetachedFromWindow()
  }

  /** One tile: a small "Aa" playing the tile's own animation on a 2 s
   *  cycle (In: comes in and holds; Out: holds and leaves; Loop: keeps
   *  going), with the name below. */
  private inner class Tile(val type: Int, val title: String) : View(context) {
    var selectedTile = false
    private val bg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = EditorDesignTokens.Colors.elevatedSurface }
    private val border = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 2f * density; color = EditorDesignTokens.Colors.selectedToolTint }
    private val glyph = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 18f * density; typeface = Typeface.DEFAULT_BOLD; textAlign = Paint.Align.CENTER; color = Color.WHITE }
    private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 12f * density; textAlign = Paint.Align.CENTER }
    private val none = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 1.8f * density; color = EditorDesignTokens.Colors.textSecondary }
    private val rect = RectF()

    init {
      contentDescription = title
      isClickable = true
    }

    override fun onDraw(canvas: Canvas) {
      val w = width.toFloat()
      val h = height.toFloat()
      val radius = 12f * density
      rect.set(0f, 0f, w, h)
      canvas.drawRoundRect(rect, radius, radius, bg)
      if (selectedTile) {
        val inset = border.strokeWidth / 2
        rect.set(inset, inset, w - inset, h - inset)
        canvas.drawRoundRect(rect, radius, radius, border)
      }
      val boxL = 4f * density
      val boxT = 4f * density
      val boxR = w - 4f * density
      val boxB = h - 26f * density
      val cx = w / 2
      val cy = (boxT + boxB) / 2
      if (type == 0) {
        val r = 9f * density
        canvas.drawCircle(cx, cy, r, none)
        canvas.drawLine(cx - r * 0.7f, cy + r * 0.7f, cx + r * 0.7f, cy - r * 0.7f, none)
      } else {
        val s = tileState()
        if (s.alpha > 0.01f) {
          canvas.save()
          canvas.clipRect(boxL, boxT, boxR, boxB)
          // Offsets are canvas fractions — exaggerated so they read in a tile.
          canvas.translate(cx + s.offsetX * (boxR - boxL) * 2.5f, cy + s.offsetY * (boxB - boxT) * 4f)
          canvas.rotate(s.rotation)
          canvas.scale(s.scale, s.scale)
          val tw = glyph.measureText("Aa")
          if (s.reveal < 1f) canvas.clipRect(-tw / 2 - 2f, -h, -tw / 2 + tw * s.reveal, h)
          glyph.alpha = (s.alpha.coerceIn(0f, 1f) * 255).toInt()
          canvas.drawText("Aa", 0f, -(glyph.ascent() + glyph.descent()) / 2, glyph)
          canvas.restore()
        }
      }
      label.color = if (selectedTile) EditorDesignTokens.Colors.textPrimary else EditorDesignTokens.Colors.textSecondary
      canvas.drawText(title, cx, h - 9f * density, label)
    }

    private fun tileState(): TextAnimation.State {
      val t = (SystemClock.uptimeMillis() - startMs) % 2000L
      val base = TextAnimConfig(inDurationMs = 600L, outDurationMs = 600L, loopPeriodMs = 1000L)
      val (c, seg) = when (tab) {
        0 -> base.copy(inType = type) to (200L..100_000L)
        1 -> base.copy(outType = type) to (-100_000L..1600L)
        else -> base.copy(loopType = type) to (0L..100_000L)
      }
      if (t !in seg) return TextAnimation.State(alpha = 0f)
      return TextAnimation.state(t, listOf(seg), c)
    }
  }
}
