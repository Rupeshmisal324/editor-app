package com.intoactive.app.mediaeditor

import android.graphics.ColorMatrix

// Shared ColorMatrix builders for MediaEditorActivity's Edit-panel
// adjustments (brightness/contrast/saturation/...), composed via
// ColorMatrix.postConcat. The named filters use FilterLut instead.

internal fun saturationMatrix(saturation: Float): ColorMatrix =
  ColorMatrix().apply { setSaturation(saturation) }

internal fun contrastMatrix(contrast: Float): ColorMatrix {
  val translate = (1 - contrast) * 128f
  return ColorMatrix(
    floatArrayOf(
      contrast, 0f, 0f, 0f, translate,
      0f, contrast, 0f, 0f, translate,
      0f, 0f, contrast, 0f, translate,
      0f, 0f, 0f, 1f, 0f,
    ),
  )
}

internal fun tintMatrix(rMul: Float, gMul: Float, bMul: Float): ColorMatrix =
  ColorMatrix(
    floatArrayOf(
      rMul, 0f, 0f, 0f, 0f,
      0f, gMul, 0f, 0f, 0f,
      0f, 0f, bMul, 0f, 0f,
      0f, 0f, 0f, 1f, 0f,
    ),
  )

internal fun brightnessMatrix(brightness: Float): ColorMatrix {
  val translate = brightness * 255f
  return ColorMatrix(
    floatArrayOf(
      1f, 0f, 0f, 0f, translate,
      0f, 1f, 0f, 0f, translate,
      0f, 0f, 1f, 0f, translate,
      0f, 0f, 0f, 1f, 0f,
    ),
  )
}

/** Filters-panel category tabs — same as iOS's PhotoFilter.Category. */
internal enum class FilterCategory(val label: String) {
  CLASSIC("Classic"),
  FILM("Film"),
  CINEMA("Cinema"),
  VIBES("Vibes"),
  /** Photo only — spatial effects drawn by ArtisticEffects, no lookup table. */
  ARTISTIC("Artistic"),
}

/** The Filters panel's looks — same list, order, labels and categories as
 *  iOS's PhotoFilter. Each look is a lookup table rendered from the iOS
 *  filter itself (assets/filter_luts, see FilterLut), so both platforms
 *  match. Original has none and shows first in every tab. The enum NAME is
 *  saved in re-edit projects, so never rename one. */
internal enum class PhotoFilter(val label: String, val category: FilterCategory, val lutAssetName: String?) {
  ORIGINAL("Original", FilterCategory.CLASSIC, null),
  // Classic
  VIVID("Vivid", FilterCategory.CLASSIC, "vivid"),
  WARM("Warm", FilterCategory.CLASSIC, "warm"),
  VINTAGE("Vintage", FilterCategory.CLASSIC, "vintage"),
  BLACK_AND_WHITE("B&W", FilterCategory.CLASSIC, "black_and_white"),
  COOL("Cool", FilterCategory.CLASSIC, "cool"),
  CHROME("Chrome", FilterCategory.CLASSIC, "chrome"),
  NOIR("Noir", FilterCategory.CLASSIC, "noir"),
  TRANSFER("Transfer", FilterCategory.CLASSIC, "transfer"),
  PROCESS("Process", FilterCategory.CLASSIC, "process"),
  // Film
  FADE("Fade", FilterCategory.FILM, "fade"),
  INSTANT("Instant", FilterCategory.FILM, "instant"),
  TONAL("Tonal", FilterCategory.FILM, "tonal"),
  MATTE("Matte", FilterCategory.FILM, "matte"),
  GOLDEN("Golden", FilterCategory.FILM, "golden"),
  EXPIRED("Expired", FilterCategory.FILM, "expired"),
  RETRO("Retro", FilterCategory.FILM, "retro"),
  POLAR("Polar", FilterCategory.FILM, "polar"),
  // Cinema
  TEAL_ORANGE("Teal", FilterCategory.CINEMA, "teal_orange"),
  MOODY("Moody", FilterCategory.CINEMA, "moody"),
  MIDNIGHT("Midnight", FilterCategory.CINEMA, "midnight"),
  DUSK("Dusk", FilterCategory.CINEMA, "dusk"),
  BLEACH("Bleach", FilterCategory.CINEMA, "bleach"),
  DRAMA("Drama", FilterCategory.CINEMA, "drama"),
  // Vibes
  PASTEL("Pastel", FilterCategory.VIBES, "pastel"),
  SUNSET("Sunset", FilterCategory.VIBES, "sunset"),
  ROSE("Rose", FilterCategory.VIBES, "rose"),
  MINT("Mint", FilterCategory.VIBES, "mint"),
  LAVENDER("Lavender", FilterCategory.VIBES, "lavender"),
  SEPIA("Sepia", FilterCategory.VIBES, "sepia"),
  DUO("Duo", FilterCategory.VIBES, "duo"),
  POP("Pop", FilterCategory.VIBES, "pop"),
  // Artistic (photo only)
  SKETCH("Sketch", FilterCategory.ARTISTIC, null),
  COMIC("Comic", FilterCategory.ARTISTIC, null),
  HALFTONE("Halftone", FilterCategory.ARTISTIC, null),
  PIXEL("Pixel", FilterCategory.ARTISTIC, null),
  CRYSTAL("Crystal", FilterCategory.ARTISTIC, null),
  POSTER("Poster", FilterCategory.ARTISTIC, null),
  NEON("Neon", FilterCategory.ARTISTIC, null),
}
