import UIKit

/// Shared design tokens for the image editor's UI shell — colors, spacing,
/// typography, and motion timings, so every panel/component pulls from one
/// source instead of hardcoding values per-view. UI-only: does not touch
/// the existing crop/filter/text/sticker editing logic in
/// MediaEditorViewController — components read these tokens, nothing more.
enum EditorDesignTokens {

  enum Colors {
    // Redesign palette (Snapseed-style, same values on Android): one dark
    // ground for screen/top bar/tool bar, a lighter panel surface, tiles.
    static let canvasBackground = UIColor(red: 0x0E / 255, green: 0x0F / 255, blue: 0x11 / 255, alpha: 1)
    static let chromeBackground = UIColor(red: 0x0E / 255, green: 0x0F / 255, blue: 0x11 / 255, alpha: 1)
    /// Slide-up panels, the layer action bar and the text-entry toolbar.
    static let panelBackground = UIColor(red: 0x17 / 255, green: 0x18 / 255, blue: 0x1B / 255, alpha: 1)
    static let elevatedSurface = UIColor(red: 0x20 / 255, green: 0x22 / 255, blue: 0x27 / 255, alpha: 1)
    /// The editor's own accent — deliberately NOT the app's `Color.accent`
    /// (#9D0B0E): CLAUDE.md's Critical Rule #2 reserves that red for the iA
    /// logo mark only, never UI elements. Confirmed with the user.
    static let accent = UIColor(red: 0x2F / 255, green: 0x6F / 255, blue: 0xEB / 255, alpha: 1)
    /// Redesign (Snapseed-style): the soft tile behind the selected tool
    /// and that tool's icon/label colour. Same values on Android.
    static let selectedToolTile = UIColor(red: 0x20 / 255, green: 0x22 / 255, blue: 0x27 / 255, alpha: 1)
    static let selectedToolTint = UIColor(red: 0x8F / 255, green: 0xB2 / 255, blue: 0xFF / 255, alpha: 1)
    /// The video trim scrubber's border/handle color — deliberately plain
    /// system yellow, matching the native Photos/iMovie trim-tool
    /// convention the user referenced directly, not the editor's own
    /// purple `accent`.
    // Video redesign: the editor accent (was system yellow) so the video
    // timeline matches the image editor's blue selection colour.
    static let trimHandle = UIColor(red: 0x2F / 255, green: 0x6F / 255, blue: 0xEB / 255, alpha: 1)
    static let textPrimary = UIColor.white
    static let textSecondary = UIColor(red: 0xA1 / 255, green: 0xA4 / 255, blue: 0xAA / 255, alpha: 1)
    static let divider = UIColor(red: 0x2C / 255, green: 0x2E / 255, blue: 0x33 / 255, alpha: 1)
    /// Same red as Android's identical token — used for the bottom tray's
    /// active-tab indicator dot, per the user's explicit "icons white...
    /// active icon shows red dot below" request (not the app's reserved
    /// logo-only accent red).
    static let danger = UIColor(red: 0xE2 / 255, green: 0x4B / 255, blue: 0x4A / 255, alpha: 1)
    /// The music layer row's color — distinct from the text/sticker/
    /// overlay purple/orange/accent trio, matching the common audio-
    /// track-color convention. Same value as Android's identical token.
    /// Darker/more saturated (emerald-700) per the user's explicit
    /// "make these all three layers color dark, increase saturation...
    /// just like Instagram edit app" request — was a brighter, less
    /// saturated green (#22C55E) before.
    static let musicLayer = UIColor(red: 0x04 / 255, green: 0x78 / 255, blue: 0x57 / 255, alpha: 1)
    /// Voice-over track (teal).
    static let voiceLayer = UIColor(red: 0x0E / 255, green: 0x74 / 255, blue: 0x90 / 255, alpha: 1)
    /// The text layer row's color — was the system-default `.systemPurple`
    /// (a lighter, less saturated purple) before the same "dark,
    /// saturated, Instagram-style" request as musicLayer above. Violet-700.
    static let textLayer = UIColor(red: 0x6D / 255, green: 0x28 / 255, blue: 0xD9 / 255, alpha: 1)
    /// The sticker layer row's color — was the system-default
    /// `.systemOrange` (a brighter, less saturated orange) before the same
    /// "dark, saturated, Instagram-style" request as musicLayer above.
    /// Amber-700.
    static let stickerLayer = UIColor(red: 0xB4 / 255, green: 0x53 / 255, blue: 0x09 / 255, alpha: 1)
  }

  enum Typography {
    static let trayLabel = UIFont.systemFont(ofSize: 12, weight: .medium)
    static let panelTitle = UIFont.systemFont(ofSize: 15, weight: .semibold)
    static let sliderValue = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
  }

  enum Spacing {
    static let topBarHeight: CGFloat = 52
    static let topBarHorizontalPadding: CGFloat = 16
    static let minTapTarget: CGFloat = 44
    static let bottomTrayHeight: CGFloat = 76
    /// Redesign: the LOOKS · TOOLS · EXPORT bar under the tool rail
    /// (regular editor only, not story mode). Same on Android.
    static let lookToolsBarHeight: CGFloat = 52
    static let trayIconSize: CGFloat = 24
    static let trayIconSpacing: CGFloat = 8
    static let panelCollapsedHeight: CGFloat = 220
    static let panelExpandedHeightFraction: CGFloat = 0.4
    static let panelCornerRadius: CGFloat = 20
    static let thumbnailSize: CGFloat = 64
    static let thumbnailCornerRadius: CGFloat = 8
    static let thumbnailGutter: CGFloat = 8
    static let sliderTrackHeight: CGFloat = 4
    static let sliderThumbDiameter: CGFloat = 20
  }

  enum Motion {
    static let panelToggleDuration: TimeInterval = 0.22
    static let trayIconActiveDuration: TimeInterval = 0.12
    static let trayIconActiveScale: CGFloat = 1.08
  }
}
