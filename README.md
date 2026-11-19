# Editor

A photo and video editor app for iOS and Android. React Native 0.80.2 (legacy architecture), with the
native photo/video editor taken unchanged from IntoActiv.

- **Bundle id / application id:** `com.editorapp.editor` (change before the first store upload if you want another).
- **Version:** 1.0.0 (build 1).

## What the app does

1. **Home:** edit a photo or a video from the library, take a photo or record a video, and "My work" (everything you've edited).
2. **Editor:** the native editor (filters, adjust, text, stickers, draw, blur, overlays; for video trim, split, per-part speed, music, voice-over, layers).
3. **Result:** save to Photos (into an "Editor" album), share, edit again (photos keep their text/stickers editable for 2 days), delete.
4. **Settings:** storage used, clear My work, rate, contact, privacy policy, version.

Edits are copied into the app's Documents folder, so they stay after the editor's cache is cleaned.
Nothing is uploaded; the only network calls are the music search (Apple iTunes) in the video editor.

## Where the code is

| Part | Path |
|---|---|
| App screens | `src/screens` (Home, Result, Settings), `src/navigation.tsx` |
| Pick / capture, save / share | `src/media` |
| My work storage | `src/storage/creations.ts` |
| JS bridge to the editor | `src/native/MediaEditor` |
| Android editor (unchanged from IntoActiv) | `android/app/src/main/java/com/intoactive/app/mediaeditor` |
| iOS editor (unchanged from IntoActiv) | `ios/Editor/MediaEditor` |
| Editor resources | Android `assets/` (filters, fonts, stickers) + `res/drawable*` (`ic_editor_*`, `ic_tool_*`, `sticker_*`); iOS `ios/Stickers`, `ios/TextFonts`, `Images.xcassets`, `ios/Editor/Fonts` |

When the editor changes in IntoActiv, copy the same files across again. The Android files only differ in one line:
`import com.editorapp.editor.R` instead of `import com.intoactive.app.R`.

## Run

```sh
npm install
cd ios && bundle install && bundle exec pod install && cd ..
npm start
npm run android      # or open ios/Editor.xcworkspace in Xcode and Run
```

## Release

**Before the first upload**
- Fill in `src/config.ts`: privacy policy URL (required by both stores), support email, App Store id.
- Replace the placeholder icon (`ios/Editor/Images.xcassets/AppIcon.appiconset/icon-1024.png` and `android/app/src/main/res/mipmap-*`).

**Android (Play Store)**
1. Create an upload key once:
   `keytool -genkeypair -v -storetype PKCS12 -keystore editor-upload.keystore -alias editor -keyalg RSA -keysize 2048 -validity 10000`
2. Add to `~/.gradle/gradle.properties` (not the repo):
   ```
   EDITOR_UPLOAD_STORE_FILE=/absolute/path/editor-upload.keystore
   EDITOR_UPLOAD_STORE_PASSWORD=...
   EDITOR_UPLOAD_KEY_ALIAS=editor
   EDITOR_UPLOAD_KEY_PASSWORD=...
   ```
3. `cd android && ./gradlew bundleRelease` → `android/app/build/outputs/bundle/release/app-release.aab`.
4. Raise `versionCode` / `versionName` in `android/app/build.gradle` for each upload.

**iOS (App Store)**
1. In Xcode, select the Editor target → Signing & Capabilities → choose your team.
2. Product → Archive → Distribute App → App Store Connect.
3. Raise Version / Build in the target's General tab for each upload.

**Store forms:** data collection is "none" (no accounts, analytics or uploads). Permissions used: camera, microphone
(recording and voice-over), photo library add (saving), location only for the editor's location sticker.
