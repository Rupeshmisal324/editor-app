package com.intoactive.app.mediaeditor

import android.content.Context
import android.net.Uri
import org.json.JSONObject
import java.io.File

/**
 * Storage for the photo re-edit project (reopen an exported photo with its
 * layers still editable, Instagram/Canva-style). The project itself is an
 * opaque JSON string handed to JS next to the exported file and passed back
 * on the next open(); only this platform ever reads it, so the format is
 * Android's own (see MediaEditorActivity.saveEditProject/restore...).
 *
 * Files (untouched source photo + overlay-photo PNGs) live in
 * `cacheDir/MediaEditorProjects/<id>/`; folders untouched for
 * [MAX_AGE_MS] are deleted on the next editor open.
 */
internal object MediaEditorEditProject {
  const val VERSION = 1
  const val SOURCE_FILE_NAME = "source"
  private const val MAX_AGE_MS = 2L * 24 * 60 * 60 * 1000

  fun rootDir(context: Context): File = File(context.cacheDir, "MediaEditorProjects")

  fun dir(context: Context, id: String): File = File(rootDir(context), id)

  /** Parsed project + its source file, or null if missing/stale/wrong version. */
  fun decode(context: Context, json: String?): Pair<JSONObject, File>? {
    if (json.isNullOrEmpty()) return null
    val obj = runCatching { JSONObject(json) }.getOrNull() ?: return null
    if (obj.optInt("version") != VERSION) return null
    val id = obj.optString("id")
    if (id.isEmpty()) return null
    val source = File(dir(context, id), SOURCE_FILE_NAME)
    if (!source.exists()) return null
    return obj to source
  }

  /** Copies [uriString] (content://, file:// or a bare path) to [dest]. */
  fun copySource(context: Context, uriString: String, dest: File): Boolean = runCatching {
    val uri = MediaMetadataReader.normalizedUri(uriString)
    val input = if (uri.scheme == null) File(uriString).inputStream() else context.contentResolver.openInputStream(uri)
    input?.use { inStream -> dest.outputStream().use { inStream.copyTo(it) } } != null
  }.getOrDefault(false)

  fun isSameFile(uriString: String, file: File): Boolean {
    val path = Uri.parse(uriString).let { if (it.scheme == "file") it.path else if (it.scheme == null) uriString else null }
      ?: return false
    return runCatching { File(path).canonicalPath == file.canonicalPath }.getOrDefault(false)
  }

  fun pruneStale(context: Context, keepId: String?) {
    val cutoff = System.currentTimeMillis() - MAX_AGE_MS
    rootDir(context).listFiles()?.forEach { entry ->
      if (entry.name != keepId && entry.lastModified() < cutoff) entry.deleteRecursively()
    }
  }
}
