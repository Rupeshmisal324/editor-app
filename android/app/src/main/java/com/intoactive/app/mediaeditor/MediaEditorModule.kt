package com.intoactive.app.mediaeditor

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RenderEffect
import android.graphics.RuntimeShader
import android.graphics.RectF
import android.media.ExifInterface
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.net.Uri
import android.view.View
import android.opengl.GLES20
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import androidx.media3.effect.RgbMatrix
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import kotlin.concurrent.thread
import com.facebook.react.bridge.ActivityEventListener
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.BaseActivityEventListener
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.UiThreadUtil
import com.facebook.react.bridge.WritableArray
import com.facebook.react.bridge.WritableMap
import com.facebook.react.uimanager.UIManagerHelper
import org.json.JSONArray
import org.json.JSONObject

private const val REQUEST_CODE = 9821

/**
 * RN bridge entry point for the native media editor. Launches
 * MediaEditorActivity via startActivityForResult and resolves the pending
 * Promise from onActivityResult — never streams editing state back over the
 * bridge (see project architecture doc). Same approach react-native-image-
 * crop-picker uses under the hood.
 */
class MediaEditorModule(private val reactContext: ReactApplicationContext) :
  ReactContextBaseJavaModule(reactContext) {

  private var pendingPromise: Promise? = null

  private val activityEventListener: ActivityEventListener =
    object : BaseActivityEventListener() {
      override fun onActivityResult(
        activity: Activity,
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
      ) {
        if (requestCode != REQUEST_CODE) return
        val promise = pendingPromise ?: return
        pendingPromise = null

        if (resultCode != Activity.RESULT_OK || data == null) {
          promise.resolve(cancelledResult())
          return
        }

        when (data.getStringExtra(MediaEditorActivity.EXTRA_RESULT_STATUS)) {
          "success" -> promise.resolve(
            successResult(
              type = data.getStringExtra(MediaEditorActivity.EXTRA_RESULT_TYPE).orEmpty(),
              uri = data.getStringExtra(MediaEditorActivity.EXTRA_RESULT_URI).orEmpty(),
              width = data.getIntExtra(MediaEditorActivity.EXTRA_RESULT_WIDTH, 0),
              height = data.getIntExtra(MediaEditorActivity.EXTRA_RESULT_HEIGHT, 0),
              duration = data.getDoubleExtra(MediaEditorActivity.EXTRA_RESULT_DURATION, 0.0),
              stickersJson = data.getStringExtra(MediaEditorActivity.EXTRA_RESULT_STICKERS_JSON),
              editProject = data.getStringExtra(MediaEditorActivity.EXTRA_RESULT_EDIT_PROJECT),
            ),
          )
          "error" -> promise.resolve(
            errorResult(
              code = data.getStringExtra(MediaEditorActivity.EXTRA_RESULT_CODE) ?: "processing_error",
              message = data.getStringExtra(MediaEditorActivity.EXTRA_RESULT_MESSAGE) ?: "Unknown error.",
            ),
          )
          else -> promise.resolve(cancelledResult())
        }
      }
    }

  init {
    reactContext.addActivityEventListener(activityEventListener)
  }

  override fun getName() = "MediaEditorModule"

  private val previewFilterListeners =
    java.util.WeakHashMap<View, View.OnLayoutChangeListener>()

  /** Story camera live filter on Android: filters the Vision Camera view
   *  (TextureView preview) with a RenderEffect. A Skia frame processor
   *  would add a third camera stream, which some drivers (e.g. Xiaomi)
   *  refuse next to photo + video, leaving a black preview. */
  @ReactMethod
  fun setCameraPreviewFilter(viewTag: Int, input: ReadableMap, promise: Promise) {
    val matrixArray = if (input.hasKey("matrix")) input.getArray("matrix") else null
    val shaderSource = if (input.hasKey("shader")) input.getString("shader") else null
    UiThreadUtil.runOnUiThread {
      try {
        val view = UIManagerHelper.getUIManagerForReactTag(reactApplicationContext, viewTag)
          ?.resolveView(viewTag)
        if (view == null) {
          promise.reject("no_view", "No view for tag $viewTag.")
          return@runOnUiThread
        }
        previewFilterListeners.remove(view)?.let { view.removeOnLayoutChangeListener(it) }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
          promise.resolve(null)
          return@runOnUiThread
        }
        if (!shaderSource.isNullOrEmpty()) {
          val shader = RuntimeShader(shaderSource)
          val apply = { w: Int, h: Int ->
            if (w > 0 && h > 0) {
              shader.setFloatUniform("res", w.toFloat(), h.toFloat())
              view.setRenderEffect(RenderEffect.createRuntimeShaderEffect(shader, "image"))
            }
          }
          apply(view.width, view.height)
          // `res` is the view size — Layout cells mount at 0x0 first.
          val listener = View.OnLayoutChangeListener { _, l, t, r, b, ol, ot, or, ob ->
            if (r - l != or - ol || b - t != ob - ot) apply(r - l, b - t)
          }
          view.addOnLayoutChangeListener(listener)
          previewFilterListeners[view] = listener
        } else if (matrixArray != null && matrixArray.size() == 20) {
          // android.graphics.ColorMatrix wants the translation in 0-255.
          val m = FloatArray(20) { i ->
            val v = matrixArray.getDouble(i).toFloat()
            if (i % 5 == 4) v * 255f else v
          }
          view.setRenderEffect(
            RenderEffect.createColorFilterEffect(ColorMatrixColorFilter(ColorMatrix(m))),
          )
        } else {
          view.setRenderEffect(null)
        }
        promise.resolve(null)
      } catch (e: Exception) {
        promise.reject("preview_filter_failed", e.message, e)
      }
    }
  }

  @ReactMethod
  fun open(input: ReadableMap, promise: Promise) {
    val uri = input.getString("uri")
    val type = input.getString("type")

    if (uri.isNullOrEmpty() || (type != "image" && type != "video")) {
      promise.resolve(errorResult("invalid_media", "Missing or invalid 'uri'/'type' in input."))
      return
    }

    val activity = currentActivity
    if (activity == null) {
      promise.resolve(errorResult("processing_error", "No current activity to launch the editor from."))
      return
    }

    // Crosses the bridge once, here, at open time — never re-fetched or
    // streamed while the editor is up (see project architecture doc).
    // Intent extras can't carry a ReadableArray of maps directly, so this
    // serializes to a JSON string; MediaEditorActivity parses it back with
    // org.json (already in the Android SDK, no new dependency).
    val musicTracksJson = JSONArray().apply {
      input.getArray("musicTracks")?.let { tracks ->
        for (i in 0 until tracks.size()) {
          val track = tracks.getMap(i) ?: continue
          put(
            JSONObject().apply {
              put("id", track.getString("id").orEmpty())
              put("title", track.getString("title").orEmpty())
              put("artist", track.getString("artist").orEmpty())
              put("albumArt", track.getString("albumArt").orEmpty())
              put("audioUrl", track.getString("audioUrl").orEmpty())
            },
          )
        }
      }
    }.toString()

    // Story camera flow only — swaps the primary button's label to "Share
    // your story"; export/result plumbing below is identical either way.
    val isStoryMode = input.hasKey("isStoryMode") && input.getBoolean("isStoryMode")
    // Story rail's Location picker (Google Places) — optional; the picker
    // shows "Location search unavailable" when it's absent.
    val placesApiKey = if (input.hasKey("placesApiKey")) input.getString("placesApiKey").orEmpty() else ""
    // Photo re-edit project from a previous export (opaque JSON).
    val editProject = if (input.hasKey("editProject")) input.getString("editProject") else null

    // A second open while the editor is already opening/open (e.g. a
    // double-tap) would overwrite the first call's promise, so the first
    // screen never got its result. Keep the first; the duplicate cancels.
    if (pendingPromise != null) {
      promise.resolve(cancelledResult())
      return
    }
    pendingPromise = promise
    val cacheDir = reactContext.cacheDir
    Thread { pruneOldEditorFiles(cacheDir) }.start()
    val intent = Intent(activity, MediaEditorActivity::class.java).apply {
      putExtra(MediaEditorActivity.EXTRA_URI, uri)
      putExtra(MediaEditorActivity.EXTRA_TYPE, type)
      putExtra(MediaEditorActivity.EXTRA_MUSIC_TRACKS_JSON, musicTracksJson)
      putExtra(MediaEditorActivity.EXTRA_IS_STORY_MODE, isStoryMode)
      putExtra(MediaEditorActivity.EXTRA_PLACES_API_KEY, placesApiKey)
      putExtra(MediaEditorActivity.EXTRA_EDIT_PROJECT, editProject)
    }
    activity.startActivityForResult(intent, REQUEST_CODE)
  }

  // ─── Story camera helpers ─────────────────────────────────────────────

  /** Layout mode: draws each captured photo into its cell of one canvas.
   *  Each cell's x/y/w/h is normalized (0-1) to the canvas. The camera
   *  preview is shown per cell, aspect-filled, so each photo is center-
   *  cropped to its cell's shape here to match. `previewAspect` (portrait
   *  width/height of the camera's preview stream) crops the photo to what
   *  the preview could see first — photos are usually 4:3 while the
   *  preview is 16:9. `mirror` flips a front-camera photo so it matches the
   *  mirrored preview. */
  @ReactMethod
  fun composeCollage(input: ReadableMap, promise: Promise) {
    val cells = input.getArray("cells")
    if (cells == null || cells.size() == 0) {
      promise.reject("invalid_input", "No cells to compose.")
      return
    }
    val width = if (input.hasKey("width")) input.getDouble("width").toInt() else 1080
    val height = if (input.hasKey("height")) input.getDouble("height").toInt() else 1920
    val cellMaps = (0 until cells.size()).mapNotNull { cells.getMap(it) }
    thread {
      try {
        val output = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        canvas.drawColor(Color.BLACK)
        val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
        for (cell in cellMaps) {
          val path = cell.getString("uri") ?: continue
          val x = cell.getDouble("x")
          val y = cell.getDouble("y")
          val w = cell.getDouble("w")
          val h = cell.getDouble("h")
          val mirror = cell.hasKey("mirror") && cell.getBoolean("mirror")
          val previewAspect = if (cell.hasKey("previewAspect")) cell.getDouble("previewAspect") else 0.0
          val dest = RectF((x * width).toFloat(), (y * height).toFloat(), ((x + w) * width).toFloat(), ((y + h) * height).toFloat())
          val image = decodeUpright(path, mirror, maxDimension = (maxOf(dest.width(), dest.height()) * 2.5f).toInt()) ?: continue

          // Center crop to the cell's aspect — what the aspect-fill
          // per-cell preview showed.
          val cellAspect = dest.width().toDouble() / dest.height()
          val imageW = image.width.toDouble()
          val imageH = image.height.toDouble()
          // What the preview stream could see (centered), then the part of
          // that the aspect-filled cell showed.
          var visibleW = imageW
          var visibleH = imageH
          if (previewAspect > 0) {
            if (visibleW / visibleH > previewAspect) visibleW = visibleH * previewAspect
            else visibleH = visibleW / previewAspect
          }
          var cropW = visibleW
          var cropH = visibleW / cellAspect
          if (cropH > visibleH) {
            cropH = visibleH
            cropW = visibleH * cellAspect
          }
          val cropX = (imageW - cropW) / 2
          val cropY = (imageH - cropH) / 2
          val src = Rect(cropX.toInt(), cropY.toInt(), (cropX + cropW).toInt(), (cropY + cropH).toInt())
          canvas.drawBitmap(image, src, dest, paint)
          image.recycle()
        }
        val outFile = File(reactContext.cacheDir, "story_collage_${UUID.randomUUID()}.jpg")
        FileOutputStream(outFile).use { output.compress(Bitmap.CompressFormat.JPEG, 92, it) }
        output.recycle()
        promise.resolve(
          Arguments.createMap().apply {
            putString("uri", Uri.fromFile(outFile).toString())
            putInt("width", width)
            putInt("height", height)
          },
        )
      } catch (e: Throwable) {
        promise.reject("export_failed", e.message ?: "Could not compose collage.", e)
      }
    }
  }

  /** Boomerang mode: samples `frameCount` frames evenly from the short
   *  recorded clip at `videoUri`, then encodes them forward then backward,
   *  repeated `loops` times, into an H.264 mp4 at `fps`. */
  @ReactMethod
  fun makeBoomerang(input: ReadableMap, promise: Promise) {
    val videoUri = if (input.hasKey("videoUri")) input.getString("videoUri") else null
    if (videoUri.isNullOrEmpty()) {
      promise.reject("invalid_input", "Missing 'videoUri'.")
      return
    }
    val frameCount = if (input.hasKey("frameCount")) input.getInt("frameCount").coerceAtLeast(2) else 15
    val fps = if (input.hasKey("fps")) input.getInt("fps").coerceAtLeast(1) else 24
    val loops = if (input.hasKey("loops")) input.getInt("loops").coerceAtLeast(1) else 3
    thread {
      var encoder: MediaCodec? = null
      var muxer: MediaMuxer? = null
      val frames = mutableListOf<Bitmap>()
      try {
        val retriever = MediaMetadataRetriever()
        try {
          val videoPath = if (videoUri.startsWith("file://")) Uri.parse(videoUri).path else videoUri
          retriever.setDataSource(videoPath)
          val durationUs = (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L) * 1000
          if (durationUs > 0) {
            for (index in 0 until frameCount) {
              // getFrameAtTime already applies the clip's rotation metadata.
              // Decoded small (longest side 1280 = a 720-wide portrait frame).
              val frame = retriever.scaledFrameAt(durationUs * index / frameCount, MediaMetadataRetriever.OPTION_CLOSEST, 1280) ?: continue
              // 720p keeps up to ~40 decoded frames (a 5s hold) light on memory.
              val frameScale = minOf(1f, 720f / frame.width)
              if (frameScale < 1f) {
                frames.add(Bitmap.createScaledBitmap(frame, (frame.width * frameScale).toInt(), (frame.height * frameScale).toInt(), true))
                frame.recycle()
              } else {
                frames.add(frame)
              }
            }
          }
        } finally {
          retriever.release()
        }
        if (frames.size < 2) {
          promise.reject("invalid_input", "Not enough frames for a boomerang.")
          return@thread
        }
        // Forward, then backward without repeating either end frame.
        val pingPong = frames + frames.subList(1, frames.size - 1).reversed()
        val sequence = (0 until loops).flatMap { pingPong }

        // Even dimensions (H.264), capped at 720 wide.
        val first = frames.first()
        val scale = minOf(1f, 720f / first.width)
        val outW = (first.width * scale).toInt() / 2 * 2
        val outH = (first.height * scale).toInt() / 2 * 2

        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, outW, outH).apply {
          setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
          setInteger(MediaFormat.KEY_BIT_RATE, 8_000_000)
          setInteger(MediaFormat.KEY_FRAME_RATE, fps)
          setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        encoder = codec
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = codec.createInputSurface()
        codec.start()

        val outFile = File(reactContext.cacheDir, "story_boomerang_${UUID.randomUUID()}.mp4")
        val mux = MediaMuxer(outFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        muxer = mux
        var trackIndex = -1
        var muxerStarted = false
        val bufferInfo = MediaCodec.BufferInfo()
        val frameDurationUs = 1_000_000L / fps
        val paint = Paint(Paint.FILTER_BITMAP_FLAG)
        val destRect = Rect(0, 0, outW, outH)

        fun drain(endOfStream: Boolean) {
          if (endOfStream) codec.signalEndOfInputStream()
          while (true) {
            val index = codec.dequeueOutputBuffer(bufferInfo, 10_000)
            when {
              index == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!endOfStream) return
              index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                trackIndex = mux.addTrack(codec.outputFormat)
                mux.start()
                muxerStarted = true
              }
              index >= 0 -> {
                val encoded = codec.getOutputBuffer(index)
                if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) bufferInfo.size = 0
                if (bufferInfo.size > 0 && encoded != null && muxerStarted) {
                  encoded.position(bufferInfo.offset)
                  encoded.limit(bufferInfo.offset + bufferInfo.size)
                  mux.writeSampleData(trackIndex, encoded, bufferInfo)
                }
                codec.releaseOutputBuffer(index, false)
                if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
              }
            }
          }
        }

        sequence.forEachIndexed { i, bitmap ->
          val canvas = surface.lockHardwareCanvas()
          canvas.drawColor(Color.BLACK)
          canvas.drawBitmap(bitmap, null, destRect, paint)
          surface.unlockCanvasAndPost(canvas)
          drain(endOfStream = false)
          // Canvas-drawn surface frames carry no explicit timestamp, so pace
          // them in real time relative to the target fps.
          Thread.sleep(frameDurationUs / 1000)
        }
        drain(endOfStream = true)
        surface.release()

        promise.resolve(
          Arguments.createMap().apply {
            putString("uri", Uri.fromFile(outFile).toString())
            putDouble("duration", sequence.size.toDouble() / fps)
            putInt("width", outW)
            putInt("height", outH)
          },
        )
      } catch (e: Throwable) {
        promise.reject("export_failed", e.message ?: "Boomerang export failed.", e)
      } finally {
        try { encoder?.stop() } catch (_: Throwable) {}
        encoder?.release()
        try { muxer?.stop() } catch (_: Throwable) {}
        muxer?.release()
        frames.forEach { it.recycle() }
      }
    }
  }

  /** Bakes a story-camera live filter into a captured photo or video.
   *  `matrix` is the same 20-value row-major color matrix (translation
   *  normalized 0-1) the Skia camera preview draws with, so the result
   *  matches the preview. */
  @OptIn(UnstableApi::class)
  @ReactMethod
  fun applyColorMatrix(input: ReadableMap, promise: Promise) {
    val uri = if (input.hasKey("uri")) input.getString("uri") else null
    val type = if (input.hasKey("type")) input.getString("type") else null
    val matrixArray = if (input.hasKey("matrix")) input.getArray("matrix") else null
    if (uri.isNullOrEmpty() || type == null || matrixArray == null || matrixArray.size() != 20) {
      promise.reject("invalid_input", "Missing 'uri', 'type' or a 20-value 'matrix'.")
      return
    }
    val m = FloatArray(20) { matrixArray.getDouble(it).toFloat() }

    if (type == "image") {
      thread {
        try {
          val image = decodeUpright(uri, mirror = false, maxDimension = 4096)
          if (image == null) {
            promise.reject("export_failed", "Could not read photo.")
            return@thread
          }
          // android.graphics.ColorMatrix wants the translation in 0-255.
          val androidMatrix = ColorMatrix(FloatArray(20) { i -> if (i % 5 == 4) m[i] * 255f else m[i] })
          val output = Bitmap.createBitmap(image.width, image.height, Bitmap.Config.ARGB_8888)
          Canvas(output).drawBitmap(image, 0f, 0f, Paint().apply { colorFilter = ColorMatrixColorFilter(androidMatrix) })
          image.recycle()
          val outFile = File(reactContext.cacheDir, "story_filtered_${UUID.randomUUID()}.jpg")
          FileOutputStream(outFile).use { output.compress(Bitmap.CompressFormat.JPEG, 92, it) }
          output.recycle()
          promise.resolve(Arguments.createMap().apply { putString("uri", Uri.fromFile(outFile).toString()) })
        } catch (e: Throwable) {
          promise.reject("export_failed", e.message ?: "Could not filter photo.", e)
        }
      }
      return
    }

    // Column-major 4x4 for Media3's GL RgbMatrix (same layout as
    // PhotoFilterRgbMatrix), translation already normalized.
    val glMatrix = floatArrayOf(
      m[0], m[5], m[10], 0f,
      m[1], m[6], m[11], 0f,
      m[2], m[7], m[12], 0f,
      m[4], m[9], m[14], 1f,
    )
    val filterEffect = RgbMatrix { _, _ -> glMatrix }
    // Transformer must be created and started on a Looper thread.
    Handler(Looper.getMainLooper()).post {
      try {
        val outFile = File(reactContext.cacheDir, "story_filtered_${UUID.randomUUID()}.mp4")
        val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.parse(if (uri.startsWith("/")) "file://$uri" else uri)))
          .setEffects(Effects(emptyList(), listOf(filterEffect)))
          .build()
        Transformer.Builder(reactContext)
          .addListener(object : Transformer.Listener {
            override fun onCompleted(composition: Composition, exportResult: ExportResult) {
              promise.resolve(Arguments.createMap().apply { putString("uri", Uri.fromFile(outFile).toString()) })
            }
            override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
              promise.reject("export_failed", exportException.message ?: "Could not filter video.", exportException)
            }
          })
          .build()
          .start(item, outFile.absolutePath)
      } catch (e: Throwable) {
        promise.reject("export_failed", e.message ?: "Could not filter video.", e)
      }
    }
  }

  /** Bakes a story-camera shader effect into a recorded video. `shader` /
   *  `vertexShader` are the effect's GLSL ES 1.00 program, translated in JS
   *  from the same SkSL the live preview runs (utils/storyEffectShaders.ts):
   *  the frame is `uTexSampler`, its pixel size `res`. */
  @OptIn(UnstableApi::class)
  @ReactMethod
  fun applyShaderEffect(input: ReadableMap, promise: Promise) {
    val uri = if (input.hasKey("uri")) input.getString("uri") else null
    val fragmentShader = if (input.hasKey("shader")) input.getString("shader") else null
    val vertexShader = if (input.hasKey("vertexShader")) input.getString("vertexShader") else null
    if (uri.isNullOrEmpty() || fragmentShader.isNullOrEmpty() || vertexShader.isNullOrEmpty()) {
      promise.reject("invalid_input", "Missing 'uri', 'shader' or 'vertexShader'.")
      return
    }
    val effect = StoryShaderEffect(vertexShader, fragmentShader)
    // Transformer must be created and started on a Looper thread.
    Handler(Looper.getMainLooper()).post {
      try {
        val outFile = File(reactContext.cacheDir, "story_effect_${UUID.randomUUID()}.mp4")
        val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.parse(if (uri.startsWith("/")) "file://$uri" else uri)))
          .setEffects(Effects(emptyList(), listOf(effect)))
          .build()
        Transformer.Builder(reactContext)
          .addListener(object : Transformer.Listener {
            override fun onCompleted(composition: Composition, exportResult: ExportResult) {
              promise.resolve(Arguments.createMap().apply { putString("uri", Uri.fromFile(outFile).toString()) })
            }
            override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
              promise.reject("export_failed", exportException.message ?: "Could not apply effect to video.", exportException)
            }
          })
          .build()
          .start(item, outFile.absolutePath)
      } catch (e: Throwable) {
        promise.reject("export_failed", e.message ?: "Could not apply effect to video.", e)
      }
    }
  }

  /** Decodes a local image (plain path or file:// URI) downsampled to about
   *  `maxDimension`, with its EXIF rotation baked in and optionally flipped
   *  horizontally. */
  private fun decodeUpright(pathOrUri: String, mirror: Boolean, maxDimension: Int): Bitmap? {
    val path = if (pathOrUri.startsWith("file://")) Uri.parse(pathOrUri).path ?: return null else pathOrUri
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(path, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
    var sample = 1
    while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxDimension) sample *= 2
    val decoded = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
    // Flip tags count too: a front-camera photo is saved un-mirrored with
    // FLIP_HORIZONTAL so it displays like the mirrored preview — ignoring
    // it flipped story selfies the other way from what the camera showed.
    val (rotation, exifFlip) = try {
      when (ExifInterface(path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
        ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> 0f to true
        ExifInterface.ORIENTATION_ROTATE_180 -> 180f to false
        ExifInterface.ORIENTATION_FLIP_VERTICAL -> 180f to true
        ExifInterface.ORIENTATION_TRANSPOSE -> 90f to true
        ExifInterface.ORIENTATION_ROTATE_90 -> 90f to false
        ExifInterface.ORIENTATION_TRANSVERSE -> 270f to true
        ExifInterface.ORIENTATION_ROTATE_270 -> 270f to false
        else -> 0f to false
      }
    } catch (_: Throwable) { 0f to false }
    val flip = exifFlip != mirror
    if (rotation == 0f && !flip) return decoded
    val matrix = Matrix().apply {
      postRotate(rotation)
      if (flip) postScale(-1f, 1f)
    }
    val upright = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
    if (upright != decoded) decoded.recycle()
    return upright
  }

  /** Editor outputs (exports, story filter/collage/boomerang/effect files,
   *  voice/silence temps) are handed to JS for upload and never deleted, so
   *  they piled up in the cache. Anything of ours older than 2 days (same
   *  window as re-edit projects) is long uploaded — removed on next open. */
  private fun pruneOldEditorFiles(dir: File) {
    val cutoff = System.currentTimeMillis() - 2L * 24 * 60 * 60 * 1000
    val ours = Regex("^([0-9a-fA-F-]{36}\\.(mp4|jpg)|(story_(collage|boomerang|filtered|effect)|voice|silence)[-_].+)$")
    dir.listFiles()?.forEach { file ->
      if (file.isFile && file.lastModified() < cutoff && ours.matches(file.name)) runCatching { file.delete() }
    }
  }

  private fun cancelledResult(): WritableMap =
    Arguments.createMap().apply { putString("status", "cancelled") }

  private fun errorResult(code: String, message: String): WritableMap =
    Arguments.createMap().apply {
      putString("status", "error")
      putString("code", code)
      putString("message", message)
    }

  private fun successResult(
    type: String,
    uri: String,
    width: Int,
    height: Int,
    duration: Double,
    stickersJson: String?,
    editProject: String? = null,
  ): WritableMap =
    Arguments.createMap().apply {
      putString("status", "success")
      putString("type", type)
      putString("uri", uri)
      putInt("width", width)
      putInt("height", height)
      putDouble("duration", duration)
      putArray("stickers", stickersArray(stickersJson))
      editProject?.let { putString("editProject", it) }
    }

  /** The editor's location-sticker metadata (JSON array string, see
   *  MediaEditorActivity.locationStickerJson) → a ReadableArray of maps.
   *  Always an array — empty when there are none or the JSON is bad. */
  private fun stickersArray(json: String?): WritableArray {
    val array = Arguments.createArray()
    val entries = runCatching { JSONArray(json ?: "[]") }.getOrNull() ?: return array
    for (i in 0 until entries.length()) {
      val entry = entries.optJSONObject(i) ?: continue
      array.pushMap(
        Arguments.createMap().apply {
          putString("type", entry.optString("type"))
          putString("name", entry.optString("name"))
          for (key in listOf("lat", "lng")) {
            if (entry.isNull(key)) putNull(key) else putDouble(key, entry.getDouble(key))
          }
          for (key in listOf("x", "y", "w", "h", "rotation", "aspect")) putDouble(key, entry.optDouble(key, 0.0))
        },
      )
    }
    return array
  }
}

/** A Media3 video effect running one story-camera shader over each frame. */
@UnstableApi
private class StoryShaderEffect(
  private val vertexShader: String,
  private val fragmentShader: String,
) : GlEffect {
  override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
    StoryShaderProgram(vertexShader, fragmentShader, useHdr)
}

@UnstableApi
private class StoryShaderProgram(
  vertexShader: String,
  fragmentShader: String,
  useHdr: Boolean,
) : BaseGlShaderProgram(/* useHighPrecisionColorComponents= */ useHdr, /* texturePoolCapacity= */ 1) {
  private val glProgram: GlProgram = try {
    GlProgram(vertexShader, fragmentShader)
  } catch (e: GlUtil.GlException) {
    throw VideoFrameProcessingException(e)
  }
  private val frameSize = FloatArray(2)

  init {
    // Full-frame quad; the vertex shader derives texture coords from it.
    glProgram.setBufferAttribute(
      "aFramePosition",
      GlUtil.getNormalizedCoordinateBounds(),
      GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
    )
  }

  override fun configure(inputWidth: Int, inputHeight: Int): Size {
    frameSize[0] = inputWidth.toFloat()
    frameSize[1] = inputHeight.toFloat()
    return Size(inputWidth, inputHeight)
  }

  override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
    try {
      glProgram.use()
      glProgram.setSamplerTexIdUniform("uTexSampler", inputTexId, /* texUnitIndex= */ 0)
      glProgram.setFloatsUniform("res", frameSize)
      glProgram.bindAttributesAndUniforms()
      GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, /* first= */ 0, /* count= */ 4)
    } catch (e: GlUtil.GlException) {
      throw VideoFrameProcessingException(e, presentationTimeUs)
    }
  }

  override fun release() {
    super.release()
    try {
      glProgram.delete()
    } catch (e: GlUtil.GlException) {
      throw VideoFrameProcessingException(e)
    }
  }
}
