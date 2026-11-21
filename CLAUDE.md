# Editor app — context for Claude

Standalone photo + video editor app for iOS and Android. Built 2026-11-19 by reusing the native
editors from the IntoActiv app (`~/Downloads/IntoActive_App`). This file is the handover from that
first session; read it before changing anything.

## Working preferences (from the user)

- Minimal, scoped changes only; flag risky or untestable changes.
- Summaries: numbered list, bold title, at most 2 lines each.
- Commit / push only when asked.
- Do NOT change the native photo/video editor UI unless asked — only the app's own screens.
- Before tapping on the Android test phone, take a screenshot first (someone else may be using it).

## Project facts

| Item | Value |
|---|---|
| Path | `~/Downloads/Editor` |
| Stack | React Native 0.80.2, **legacy architecture** (newArchEnabled=false, `RCT_NEW_ARCH_ENABLED=0`), TypeScript |
| App id / bundle id | `com.editorapp.editor` (placeholder; change before first store upload if wanted) |
| Version | 1.0.0 (build 1) |
| iOS min | 16.0, iPhone only, portrait |
| iOS signing | Team `NT4E66UMUM` (IntoActiv's team), automatic signing |
| Git | branch `main`, commit `e69c46e` (all work so far; only this file is uncommitted) |
| Remote | `origin` = https://github.com/RupeshMisal/editor-app (public, account **RupeshMisal**) |
| Design canvas | https://claude.ai/artifact/BKFprSq2qbygExn1CtNtwp (8 screens; app matches it) |

## Code layout

- `src/screens`: `OnboardingScreen` (3-page intro, once), `MainScreen` (bottom bar Home · + · Library, Create sheet, edit flow), `HomeTab`, `LibraryTab`, `ResultScreen`, `SettingsScreen`.
- `src/components`: `Icon` (svg stroke icons), `MediaTile`, `CreateSheet`, `Toast` (ToastProvider/useToast).
- `src/media`: `pickMedia` (react-native-image-picker library/camera), `exportMedia` (save to Photos album "Editor", share one/many), `useEditFlow` (pick → native editor → save to Library).
- `src/storage`: `creations.ts` (Library: copies exports into `Documents/Creations`, stores file NAMES only in AsyncStorage `editor.creations.v1`), `prefs.ts` (onboarding flag).
- `src/native/MediaEditor`: JS bridge (`openMediaEditor`, types) to the native module.
- `src/theme.ts`: tokens — bg #0B0B0D, surface #17171B, surfaceHigh #222228, text #F5F5F7, textSecondary #A1A1AA, textMuted #9A9AA4, danger #FF6B6F, white primary buttons, DM Sans.
- `src/config.ts`: privacy URL, support email, App Store id — **still empty** (Settings hides those rows until filled).
- Native editor (copied from IntoActiv):
  - Android: `android/app/src/main/java/com/intoactive/app/mediaeditor/*.kt` — only change vs IntoActiv is `import com.editorapp.editor.R`. Resources: `assets/` (filter_luts, text_fonts, sticker_catalog.json, fonts), `res/drawable*` (`ic_editor_*`, `ic_tool_*`, `sticker_*`), `res/layout/media_editor_player_view.xml`. Registered in `MainApplication.kt`; activity in manifest. Gradle: media3 1.4.1 (exoplayer/ui/effect/transformer), okhttp, recyclerview.
  - iOS: `ios/Editor/MediaEditor/*.swift` + `MediaEditorModule.m`, `ios/Editor/Editor-Bridging-Header.h` (needed because no use_frameworks), folders `ios/Stickers`, `ios/TextFonts`, `ios/Editor/Fonts` (DM Sans, in UIAppFonts), imagesets `sticker_*`, `tool_*`, `ui_*` in Images.xcassets.
- Android: `res/xml/share_download_paths.xml` overrides react-native-share's FileProvider paths to add `files/Creations/` (share was broken without it).
- When the editor changes in IntoActiv, re-copy the same files (Android: fix the `R` import line).

## Completed work (2026-11-19)

1. **Project setup**: RN 0.80.2 app "Editor", legacy arch, all libraries (navigation, screens, image-picker, camera-roll, share, fs, async-storage, video, create-thumbnail, svg), permissions, dark launch screen, placeholder app icon, Android release signing via `EDITOR_UPLOAD_*` gradle properties, README with store-release steps.
2. **Native editors moved in unchanged**: Android + iOS sources and all resources; both platforms build.
3. **Android device test (photo editor)**: filters, stickers, text fonts, export, save to `DCIM/Editor`, re-edit with editable layers all work. Fixed: Share did nothing (FileProvider path).
4. **Android device test (video editor)**: split, per-part speed (2x → 0:12 became 0:07), music search + add, export (7.6 s, H.264 + AAC), save — all work.
5. **Music fixes (in IntoActiv source, copied here)**: "Layers · 1" pill no longer overlaps the Music panel and reappears after closing; music card "plays 0:00–m:ss" now uses the speed-adjusted length (Android + iOS). These IntoActiv changes are **uncommitted in IntoActive_App**.
6. **App UI redesign**: intro, bottom bar with Create sheet, Home (hero Photo/Video, camera row, Recent / "How it works", Tools), Library (filters, date groups, multi-select save/share/delete), Result (details line, toasts), Settings (storage, clear, show intro again).
7. **Design canvas** of 8 screens made with Claude Design; app then matched to it exactly (colours, 44px buttons, 2 text-only Tools cards).
8. **Full Android screen test** against the design, plus 6 fixes: video tap-to-pause (overlay Pressable), Library header no jump in select mode, intro inner ring border, intro art fixed position, singular delete text, Tools text 2 lines.
9. **iOS**: Release build signed and installed + launched on Rupesh's iPhone 16 (devicectl). Not visually checked.
10. **GitHub**: pushed to public https://github.com/RupeshMisal/editor-app. Old private `RupeshMisal/editor` deleted by user.

11. **AdMob (2026-11-20, test ids)**: `react-native-google-mobile-ads` **pinned to 15.8.3** (v16+ fails to compile on Android legacy arch: missing `NativeAppModuleSpec`). `src/ads/ads.ts` (UMP consent → init, interstitial after every 3rd moment: new edit, edit again, save to Photos, share from Result; 60 s cooldown), `src/ads/AdBanner.tsx` (adaptive banner above the tab bar in MainScreen, hidden in select mode; also at the bottom of ResultScreen under the action buttons, and at the bottom of SettingsScreen), `src/ads/NativeAdCard.tsx` (full-width sponsored card in the Library grid after every 4th row, max 3; one after the last row if fewer; hidden in select mode). Test app ids in `app.json`. Both platforms build; not yet seen on a device.
12. **Remove ads purchase (2026-11-20)**: RevenueCat `react-native-purchases` 11.0.4 (Play Billing 9.1). `src/purchases/premium.ts` (product `remove_ads`, entitlement `no_ads`, cached in AsyncStorage `editor.adsRemoved.v1`), Settings "PREMIUM" group (Remove ads + price, Restore purchases). Paid users never start the ad SDK; buying hides ads at once. **Off until** `revenueCatIosKey` / `revenueCatAndroidKey` in `src/config.ts` are set. `react-native-iap` v17 was tried and rejected: Nitro fails to compile on iOS legacy arch (glog module error); v13 uses Billing 7 (too old).

## Open / pending

1. **GitHub under Rupeshmisal324**: user wants the repo on account Rupeshmisal324. This Mac's git login is **RupeshMisal** only. User must either transfer `RupeshMisal/editor-app` to Rupeshmisal324, or run (in their own terminal, no `!`):
   `git push https://Rupeshmisal324@github.com/Rupeshmisal324/editor.git main` with a Rupeshmisal324 token (repo scope). Then update `origin` and delete `RupeshMisal/editor-app`.
2. **Uncommitted here**: only `CLAUDE.md` (all app work is in `e69c46e`). Commit + push when asked.
3. **iOS untested on screen**: all app screens, editors, save permission, per-part speed + music fixes on iOS.
4. **Before store release**: real app icon, `src/config.ts` (privacy URL required by both stores; policy text is `docs/privacy.html` with `[DEVELOPER NAME]` / `[SUPPORT EMAIL]` placeholders, meant for GitHub Pages from `main` /docs; iOS Info.plist still has an unused location usage string, support email, App Store id), decide final bundle id, Android upload keystore.
5. **Known minor**: Android photo picker needs an extra "Done" tap; photo re-edit layers only survive 2 days (native project cache).
6. **Ads before release** (Settings "Privacy options" row added; shows only where Google requires it, e.g. EU/UK): real app ids in `app.json`, real unit ids + `USE_TEST_ADS = false` in `src/ads/ads.ts`, consent message (GDPR + iOS IDFA) in AdMob console, `app-ads.txt`, store privacy forms. Then `pod install`.
7. **Purchase setup**: create non-consumable `remove_ads` in App Store Connect + Play Console, RevenueCat project with entitlement `no_ads`, paste the 2 public keys into `src/config.ts`. Test with a sandbox (iOS) / license-tester (Play) account. **Stripe web checkout** (code done, off): RevenueCat Web Billing (Stripe) → Web Purchase Link in `AppConfig.webCheckoutUrl` (Settings "Buy on the web", iPhone + US storefront only). Turn on Redemption Links in RevenueCat and register its `rc-…` URL scheme natively (iOS Info.plist URL Types; Android VIEW intent-filter on MainActivity); `App.tsx` redeems the link. Android hidden (Google external offers need enrollment).
8. **Testing tips**: Android phone over wireless adb (`~/Library/Android/sdk/platform-tools/adb`, 720x1600). Debug builds load JS from Metro on :8081 — if IntoActiv's Metro is running there, the app shows "PlatformConstants could not be found"; use `./gradlew :app:assembleRelease` + `adb install -r` instead, or stop IntoActiv's Metro.
