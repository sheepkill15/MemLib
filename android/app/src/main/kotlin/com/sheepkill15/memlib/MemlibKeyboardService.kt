package com.sheepkill15.memlib

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.drawable.AnimatedImageDrawable
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.inputmethodservice.InputMethodService
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputContentInfo
import android.content.ClipDescription
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.FileProvider
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.Executors

/** A small native IME so the library remains available when the Flutter activity is closed. */
class MemlibKeyboardService : InputMethodService() {
    private data class Item(val id: String, val name: String, val filename: String, val folderId: String?, val favorite: Boolean, val uses: Int, val sourceType: String, val sourceId: String, val sourcePage: String?)
    private data class Folder(val id: String, val name: String)
    private data class GiphyItem(val id: String, val title: String, val previewUrl: String, val gifUrl: String, val pageUrl: String,
        val onload: String?, val onclick: String?, val onsent: String?)

    private val background = Color.rgb(24, 20, 33)
    private val panel = Color.rgb(43, 37, 56)
    private val accent = Color.rgb(189, 167, 255)
    private val muted = Color.rgb(184, 178, 196)
    private lateinit var rootView: LinearLayout
    private var libraryRoot: File? = null
    private var folders = emptyList<Folder>()
    private var items = emptyList<Item>()
    private var folderId: String? = null
    private var favorites = false
    private var search = ""
    private var searchMode = false
    private var typingMode = false
    private var symbols = false
    private var shifted = false
    private var status = "Tap a sticker to insert it"
    private var statusView: TextView? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val previewExecutor = Executors.newFixedThreadPool(3)
    private var previewGeneration = 0
    private var giphyMode = false
    private var giphyStickers = false
    private var giphyBusy = false
    private var giphyOffset = 0
    private var giphyHasMore = false
    private var giphyGeneration = 0
    private var giphyResults = emptyList<GiphyItem>()
    private val giphyPreviews = mutableMapOf<String, ByteArray>()

    override fun onEvaluateFullscreenMode(): Boolean = false

    override fun onCreateInputView(): View {
        rootView = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(7), dp(7), dp(7), dp(8))
            setBackgroundColor(this@MemlibKeyboardService.background)
        }
        reloadLibrary()
        render()
        return rootView
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        reloadLibrary()
        val variation = (info?.inputType ?: 0) and InputType.TYPE_MASK_VARIATION
        val password = variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
            variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
            variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD ||
            variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
        if (password) { typingMode = true; searchMode = false }
        if (::rootView.isInitialized) render()
    }

    private fun reloadLibrary() {
        val configured = getSharedPreferences("memlib_keyboard", MODE_PRIVATE).getString("library_root", null)
        val root = configured?.let(::File)?.canonicalFile
        libraryRoot = root?.takeIf { it.path.startsWith(filesDir.canonicalPath + File.separator) }
        try {
            val index = File(libraryRoot, "index.json")
            val data = JSONObject(index.readText())
            folders = data.optJSONArray("folders").asObjects().map { Folder(it.getString("id"), it.optString("name")) }
            items = data.optJSONArray("items").asObjects().map {
                Item(it.getString("id"), it.optString("name"), it.getString("filename"), it.optString("folderId").takeUnless(String::isEmpty), it.optBoolean("favorite"), it.optInt("useCount"), it.optString("sourceType"), it.optString("sourceId"), it.optString("sourcePage").takeUnless(String::isEmpty))
            }
            if (folderId != null && folders.none { it.id == folderId }) folderId = null
        } catch (_: Exception) {
            folders = emptyList()
            items = emptyList()
        }
    }

    private fun JSONArray?.asObjects(): List<JSONObject> =
        if (this == null) emptyList() else (0 until length()).mapNotNull { optJSONObject(it) }

    private fun render() {
        if (!::rootView.isInitialized) return
        previewGeneration++
        rootView.removeAllViews()
        statusView = null
        if (typingMode) renderTyping() else renderLibrary()
    }

    private fun renderLibrary() {
        val top = row()
        top.addView(label("Memlib", 16, accent, true), LinearLayout.LayoutParams(0, dp(38), 1f))
        top.addView(key(if (giphyMode) "Library" else "GIPHY", selected = giphyMode) {
            giphyMode = !giphyMode
            search = ""
            searchMode = giphyMode
            render()
        })
        top.addView(key("ABC") { typingMode = true; searchMode = false; render() })
        top.addView(key("🌐") { switchToNextInputMethod(false) })
        top.addView(key("↗") { openLibrary() })
        rootView.addView(top)

        val searchRow = row()
        val searchLabel = if (search.isEmpty()) {
            if (giphyMode) "⌕  Search GIPHY" else "⌕  Search your stickers"
        } else "⌕  $search"
        searchRow.addView(key(searchLabel, selected = searchMode) {
            searchMode = !searchMode
            render()
        }, LinearLayout.LayoutParams(0, dp(38), 1f))
        if (search.isNotEmpty()) searchRow.addView(key("×") { search = ""; render() })
        rootView.addView(searchRow)

        if (giphyMode) {
            val chips = row()
            chips.addView(key("GIFs", selected = !giphyStickers) { giphyStickers = false; if (search.isNotBlank()) searchGiphy(false) else render() })
            chips.addView(key("Stickers", selected = giphyStickers) { giphyStickers = true; if (search.isNotBlank()) searchGiphy(false) else render() })
            chips.addView(label("Powered by GIPHY", 11, muted), LinearLayout.LayoutParams(0, dp(38), 1f))
            rootView.addView(chips)
        } else {
            val folderScroll = HorizontalScrollView(this).apply { isHorizontalScrollBarEnabled = false }
            val chips = row()
            chips.addView(key("All", selected = folderId == null && !favorites) { folderId = null; favorites = false; render() })
            chips.addView(key("★", selected = favorites) { folderId = null; favorites = true; render() })
            for (folder in folders) chips.addView(key(folder.name.take(18), selected = folderId == folder.id) {
                folderId = folder.id; favorites = false; render()
            })
            folderScroll.addView(chips)
            rootView.addView(folderScroll, LinearLayout.LayoutParams(-1, dp(43)))
        }

        val matching = items.asSequence()
            .filter { (folderId == null || it.folderId == folderId) && (!favorites || it.favorite) && it.name.contains(search, ignoreCase = true) }
            .sortedWith(compareByDescending<Item> { it.favorite }.thenByDescending { it.uses })
            .take(36).toList()
        val scroller = ScrollView(this).apply { isFillViewport = true }
        val grid = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        if (giphyMode && giphyResults.isNotEmpty()) {
            for (batch in giphyResults.chunked(3)) {
                val line = row()
                for (item in batch) line.addView(giphyTile(item), LinearLayout.LayoutParams(0, dp(if (searchMode) 84 else 102), 1f))
                repeat(3 - batch.size) { line.addView(View(this), LinearLayout.LayoutParams(0, 1, 1f)) }
                grid.addView(line)
            }
            if (giphyHasMore) grid.addView(key("More GIPHY results") { searchGiphy(true) })
        } else if (giphyMode) {
            grid.addView(label(if (giphyBusy) "Searching GIPHY…" else "Type a reaction and press Search. GIPHY results are sent without saving them.", 14, muted),
                LinearLayout.LayoutParams(-1, dp(110)))
        } else if (matching.isEmpty()) {
            grid.addView(label(if (items.isEmpty()) "Your library is empty. Open Memlib to import images or sign in." else "No matching stickers or GIFs", 14, muted),
                LinearLayout.LayoutParams(-1, dp(110)))
        } else {
            for (batch in matching.chunked(3)) {
                val line = row()
                for (item in batch) line.addView(tile(item), LinearLayout.LayoutParams(0, dp(if (searchMode) 84 else 102), 1f))
                repeat(3 - batch.size) { line.addView(View(this), LinearLayout.LayoutParams(0, 1, 1f)) }
                grid.addView(line)
            }
        }
        scroller.addView(grid)
        rootView.addView(scroller, LinearLayout.LayoutParams(-1, dp(if (searchMode) 108 else 207)))
        if (searchMode) renderKeys(searching = true)
        statusView = label(status, 11, muted)
        rootView.addView(statusView, LinearLayout.LayoutParams(-1, dp(24)))
    }

    private fun tile(item: Item): View {
        val outer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            background = rounded(panel, 11)
            setPadding(dp(3), dp(3), dp(3), dp(3))
        }
        val file = File(File(libraryRoot, "media"), item.filename)
        val preview = ImageView(this).apply { scaleType = ImageView.ScaleType.FIT_CENTER }
        if (file.isFile) showPreview(preview, file)
        outer.addView(preview, LinearLayout.LayoutParams(-1, 0, 1f))
        outer.addView(label((if (item.favorite) "★ " else "") + item.name, 10, Color.WHITE), LinearLayout.LayoutParams(-1, dp(22)))
        outer.setOnClickListener { sendFile(file, item.id) }
        outer.setOnLongClickListener { shareFile(file); true }
        val holder = LinearLayout(this).apply { setPadding(dp(3), dp(3), dp(3), dp(3)); addView(outer, LinearLayout.LayoutParams(-1, -1)) }
        return holder
    }

    private fun giphyTile(item: GiphyItem): View {
        val outer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            background = rounded(panel, 11)
            setPadding(dp(3), dp(3), dp(3), dp(3))
        }
        val preview = ImageView(this).apply { scaleType = ImageView.ScaleType.FIT_CENTER }
        giphyPreviews[item.id]?.let { showRemotePreview(preview, it) } ?: loadGiphyPreview(item, preview)
        outer.addView(preview, LinearLayout.LayoutParams(-1, 0, 1f))
        val actions = row()
        actions.addView(label(item.title.ifBlank { "GIPHY" }, 10, Color.WHITE), LinearLayout.LayoutParams(0, dp(34), 1f))
        if (getSharedPreferences("memlib_keyboard", MODE_PRIVATE).getBoolean("allow_giphy_saves", false)) {
            val saved = items.firstOrNull { (it.sourceType == "giphy" && it.sourceId == item.id) || it.sourcePage == item.pageUrl }
            val pendingSave = isGiphySaveQueued(item)
            actions.addView(key(if (saved == null && !pendingSave) "+" else "✓") {
                if (saved == null && !pendingSave) queueGiphySave(item, favorite = false, toggle = false)
            })
            actions.addView(key(if (expectedGiphyFavorite(item, saved?.favorite == true)) "★" else "☆") {
                queueGiphySave(item, favorite = !expectedGiphyFavorite(item, saved?.favorite == true), toggle = true)
            })
        }
        outer.addView(actions, LinearLayout.LayoutParams(-1, dp(38)))
        outer.setOnClickListener { downloadGiphy(item, share = false) }
        outer.setOnLongClickListener { downloadGiphy(item, share = true); true }
        return LinearLayout(this).apply { setPadding(dp(3), dp(3), dp(3), dp(3)); addView(outer, LinearLayout.LayoutParams(-1, -1)) }
    }

    private fun searchGiphy(more: Boolean) {
        val key = getSharedPreferences("memlib_keyboard", MODE_PRIVATE).getString("giphy_key", "").orEmpty()
        if (key.isBlank()) { notice("Add the GIPHY Android key to this build."); return }
        if (search.isBlank() || giphyBusy) return
        val generation = ++giphyGeneration
        val query = search.trim()
        val offset = if (more) giphyOffset else 0
        giphyBusy = true
        if (!more) { giphyResults = emptyList(); giphyPreviews.clear(); giphyHasMore = false }
        status = "Searching GIPHY…"
        render()
        Thread {
            try {
                val uri = Uri.Builder().scheme("https").authority("api.giphy.com")
                    .appendPath("v1").appendPath(if (giphyStickers) "stickers" else "gifs").appendPath("search")
                    .appendQueryParameter("api_key", key).appendQueryParameter("q", query)
                    .appendQueryParameter("limit", "12").appendQueryParameter("offset", offset.toString())
                    .appendQueryParameter("rating", "pg").build()
                val json = JSONObject(String(fetchBytes(uri.toString(), 2 * 1024 * 1024), Charsets.UTF_8))
                val data = json.optJSONArray("data") ?: JSONArray()
                val found = (0 until data.length()).mapNotNull { index ->
                    val row = data.optJSONObject(index) ?: return@mapNotNull null
                    val images = row.optJSONObject("images") ?: return@mapNotNull null
                    val preview = (images.optJSONObject("fixed_width_small") ?: images.optJSONObject("fixed_width"))?.optString("url").orEmpty()
                    val original = images.optJSONObject("original")?.optString("url").orEmpty()
                    if (!isGiphyMedia(preview) || !isGiphyMedia(original)) return@mapNotNull null
                    val analytics = row.optJSONObject("analytics")
                    val page = row.optString("url").takeIf { it.startsWith("https://giphy.com/") } ?: "https://giphy.com/gifs/${row.optString("id")}"
                    GiphyItem(row.optString("id"), row.optString("title"), preview, original, page,
                        analytics?.optJSONObject("onload")?.optString("url"),
                        analytics?.optJSONObject("onclick")?.optString("url"),
                        analytics?.optJSONObject("onsent")?.optString("url"))
                }
                val count = json.optJSONObject("pagination")?.optInt("count", found.size) ?: found.size
                val total = json.optJSONObject("pagination")?.optInt("total_count", offset + count) ?: offset + count
                mainHandler.post {
                    if (generation != giphyGeneration) return@post
                    giphyResults = if (more) giphyResults + found else found
                    giphyOffset = offset + count
                    giphyHasMore = count > 0 && giphyOffset < total && giphyOffset < 5000
                    giphyBusy = false
                    searchMode = false
                    status = if (giphyResults.isEmpty()) "No results found" else "Tap to send · long-press to share · Powered by GIPHY"
                    render()
                }
            } catch (error: Exception) {
                mainHandler.post {
                    if (generation != giphyGeneration) return@post
                    giphyBusy = false
                    notice("GIPHY search failed: ${error.message}")
                }
            }
        }.start()
    }

    private fun loadGiphyPreview(item: GiphyItem, view: ImageView) {
        Thread {
            try {
                val bytes = fetchBytes(item.previewUrl, 2 * 1024 * 1024)
                mainHandler.post {
                    if (!giphyMode || giphyResults.none { it.id == item.id }) return@post
                    giphyPreviews[item.id] = bytes
                    showRemotePreview(view, bytes)
                    trackGiphy(item.onload)
                }
            } catch (_: Exception) { /* A missing preview does not block the original GIF. */ }
        }.start()
    }

    private fun showRemotePreview(view: ImageView, bytes: ByteArray) {
        try {
            if (Build.VERSION.SDK_INT >= 28) {
                val drawable = ImageDecoder.decodeDrawable(ImageDecoder.createSource(ByteBuffer.wrap(bytes))) { decoder, info, _ ->
                    decoder.setTargetSampleSize(maxOf(1, maxOf(info.size.width, info.size.height) / 250))
                }
                view.setImageDrawable(drawable)
                (drawable as? AnimatedImageDrawable)?.start()
            } else {
                view.setImageBitmap(BitmapFactory.decodeByteArray(bytes, 0, bytes.size))
            }
        } catch (_: Exception) { view.setImageResource(android.R.drawable.ic_menu_gallery) }
    }

    private fun downloadGiphy(item: GiphyItem, share: Boolean) {
        updateStatus("Loading GIF…")
        trackGiphy(item.onclick)
        Thread {
            try {
                val bytes = fetchBytes(item.gifUrl, 20 * 1024 * 1024)
                cacheDir.listFiles()?.filter { it.name.startsWith("memlib-share-") && System.currentTimeMillis() - it.lastModified() > 60 * 60 * 1000 }?.forEach(File::delete)
                val safeId = item.id.replace(Regex("[^A-Za-z0-9_-]"), "")
                val file = File(cacheDir, "memlib-share-${System.currentTimeMillis()}-$safeId.gif")
                file.writeBytes(bytes)
                mainHandler.post {
                    if (share) shareFile(file) else sendFile(file, null)
                    trackGiphy(item.onsent)
                }
            } catch (error: Exception) { mainHandler.post { notice("Could not load GIF: ${error.message}") } }
        }.start()
    }

    private fun queueGiphySave(item: GiphyItem, favorite: Boolean, toggle: Boolean) {
        if (!getSharedPreferences("memlib_keyboard", MODE_PRIVATE).getBoolean("allow_giphy_saves", false)) return
        updateStatus("Saving GIPHY result…")
        trackGiphy(item.onclick)
        Thread {
            var file: File? = null
            try {
                val bytes = fetchBytes(item.gifUrl, 20 * 1024 * 1024)
                val folder = File(filesDir, "pending-giphy")
                folder.mkdirs()
                val savedFile = File(folder, "${UUID.randomUUID()}.gif")
                file = savedFile
                savedFile.writeBytes(bytes)
                synchronized(MemlibKeyboardService::class.java) {
                    val prefs = getSharedPreferences("memlib_keyboard", MODE_PRIVATE)
                    val queue = JSONArray(prefs.getString("pending_giphy_saves", "[]"))
                    require(queue.length() < 30) { "Open Memlib to finish pending saves" }
                    queue.put(JSONObject().put("id", item.id).put("name", item.title.ifBlank { "GIPHY GIF" })
                        .put("sourcePage", item.pageUrl).put("path", savedFile.path)
                        .put("favorite", favorite).put("toggle", toggle))
                    prefs.edit().putString("pending_giphy_saves", queue.toString()).apply()
                }
                mainHandler.post {
                    render()
                    notice(if (toggle) "Favourite queued for Memlib" else "Saved to Memlib queue")
                }
            } catch (error: Exception) {
                file?.delete()
                mainHandler.post { notice("Could not save GIF: ${error.message}") }
            }
        }.start()
    }

    private fun isGiphySaveQueued(item: GiphyItem): Boolean {
        val queue = JSONArray(getSharedPreferences("memlib_keyboard", MODE_PRIVATE).getString("pending_giphy_saves", "[]"))
        return (0 until queue.length()).any { index ->
            val entry = queue.optJSONObject(index)
            entry != null && entry.optString("id") == item.id && !entry.optBoolean("toggle")
        }
    }

    private fun expectedGiphyFavorite(item: GiphyItem, savedFavorite: Boolean): Boolean {
        val queue = JSONArray(getSharedPreferences("memlib_keyboard", MODE_PRIVATE).getString("pending_giphy_saves", "[]"))
        var favorite = savedFavorite
        for (index in 0 until queue.length()) {
            val entry = queue.optJSONObject(index) ?: continue
            if (entry.optString("id") != item.id) continue
            favorite = if (entry.optBoolean("toggle")) entry.optBoolean("favorite") else false
        }
        return favorite
    }

    private fun isGiphyMedia(url: String): Boolean {
        val uri = Uri.parse(url)
        return uri.scheme == "https" && (uri.host == "giphy.com" || uri.host?.endsWith(".giphy.com") == true)
    }

    private fun fetchBytes(url: String, limit: Int): ByteArray {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 10000
        connection.readTimeout = 15000
        try {
            require(connection.responseCode in 200..299) { "HTTP ${connection.responseCode}" }
            require(connection.contentLengthLong <= limit || connection.contentLengthLong < 0) { "GIF is too large" }
            connection.inputStream.use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(32 * 1024)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    require(output.size() + read <= limit) { "GIF is too large" }
                    output.write(buffer, 0, read)
                }
                return output.toByteArray()
            }
        } finally { connection.disconnect() }
    }

    private fun trackGiphy(url: String?) {
        val uri = url?.let(Uri::parse) ?: return
        if (uri.scheme != "https" || uri.host != "giphy-analytics.giphy.com") return
        val prefs = getSharedPreferences("memlib_keyboard", MODE_PRIVATE)
        val customerId = prefs.getString("giphy_customer_id", null) ?: UUID.randomUUID().toString().also {
            prefs.edit().putString("giphy_customer_id", it).apply()
        }
        Thread {
            try {
                fetchBytes(uri.buildUpon().appendQueryParameter("customer_id", customerId)
                    .appendQueryParameter("ts", System.currentTimeMillis().toString()).build().toString(), 64 * 1024)
            } catch (_: Exception) { /* Analytics must not interrupt sending a GIF. */ }
        }.start()
    }

    private fun showPreview(view: ImageView, file: File) {
        val generation = previewGeneration
        previewExecutor.execute {
            val drawable: Drawable? = try {
                if (Build.VERSION.SDK_INT >= 28) {
                    ImageDecoder.decodeDrawable(ImageDecoder.createSource(file)) { decoder, info, _ ->
                        decoder.setTargetSampleSize(maxOf(1, maxOf(info.size.width, info.size.height) / 300))
                    }
                } else if (file.extension.lowercase() != "gif") {
                    BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = 4 })
                        ?.let { BitmapDrawable(resources, it) }
                } else null
            } catch (_: Exception) { null }
            mainHandler.post {
                if (generation != previewGeneration) return@post
                if (drawable == null) view.setImageResource(android.R.drawable.ic_menu_gallery)
                else {
                    view.setImageDrawable(drawable)
                    (drawable as? AnimatedImageDrawable)?.start()
                }
            }
        }
    }

    private fun sendFile(file: File, id: String?) {
        if (!file.isFile) { notice("Image is unavailable; open Memlib to sync it."); return }
        val mime = mime(file)
        val uri = FileProvider.getUriForFile(this, "$packageName.provider", file)
        val editor = currentInputEditorInfo
        val accepts = Build.VERSION.SDK_INT >= 25 && editor?.contentMimeTypes?.any { pattern ->
            pattern == mime || pattern == "image/*" || pattern == "*/*"
        } == true
        if (accepts) {
            val info = InputContentInfo(uri, ClipDescription(file.name, arrayOf(mime)), null)
            try {
                if (currentInputConnection?.commitContent(info, InputConnection.INPUT_CONTENT_GRANT_READ_URI_PERMISSION, null) == true) {
                    if (id != null) recordUse(id)
                    notice("Inserted ${file.name}")
                    return
                }
            } catch (_: Exception) { /* Some editors advertise support but reject media. */ }
        }
        (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
            .setPrimaryClip(ClipData.newUri(contentResolver, file.name, uri))
        if (id != null) recordUse(id)
        notice("Copied. This app does not accept images from keyboards; paste or long-press to share.")
    }

    private fun recordUse(id: String) {
        val prefs = getSharedPreferences("memlib_keyboard", MODE_PRIVATE)
        val queue = try { JSONArray(prefs.getString("used_ids", "[]")) } catch (_: Exception) { JSONArray() }
        queue.put(id)
        prefs.edit().putString("used_ids", queue.toString()).apply()
    }

    private fun shareFile(file: File) {
        if (!file.isFile) return
        val uri = FileProvider.getUriForFile(this, "$packageName.provider", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = mime(file)
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newUri(contentResolver, file.name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, "Share sticker or GIF").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun mime(file: File): String = when (file.extension.lowercase()) {
        "gif" -> "image/gif"; "png" -> "image/png"; "webp" -> "image/webp"; else -> "image/jpeg"
    }

    private fun openLibrary() {
        packageManager.getLaunchIntentForPackage(packageName)?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)?.let(::startActivity)
    }

    private fun renderTyping() {
        val top = row()
        top.addView(label("Memlib keyboard", 15, accent, true), LinearLayout.LayoutParams(0, dp(42), 1f))
        top.addView(key("▦ Stickers") { typingMode = false; reloadLibrary(); render() })
        top.addView(key("🌐") { switchToNextInputMethod(false) })
        rootView.addView(top)
        renderKeys(searching = false)
    }

    private fun renderKeys(searching: Boolean) {
        val rows = if (symbols) listOf("1234567890", "@#\$%&-*+()", "!\"':;/?") else listOf("qwertyuiop", "asdfghjkl", "zxcvbnm")
        for ((index, letters) in rows.withIndex()) {
            val line = row()
            if (index == 2) line.addView(key(if (shifted) "⇧" else "↑") { shifted = !shifted; render() })
            for (char in letters) {
                val shown = if (shifted) char.uppercaseChar() else char
                line.addView(key("$shown") {
                    if (searching) { search += shown; render() }
                    else currentInputConnection?.commitText("$shown", 1)
                    if (shifted) { shifted = false; render() }
                }, LinearLayout.LayoutParams(0, dp(44), 1f))
            }
            if (index == 2) line.addView(key("⌫") {
                if (searching) { if (search.isNotEmpty()) search = search.dropLast(1); render() }
                else currentInputConnection?.deleteSurroundingText(1, 0)
            })
            rootView.addView(line)
        }
        val bottom = row()
        bottom.addView(key(if (symbols) "ABC" else "?123") { symbols = !symbols; render() })
        bottom.addView(key(",") { typeOrSearch(",", searching) })
        bottom.addView(key("space") { typeOrSearch(" ", searching) }, LinearLayout.LayoutParams(0, dp(44), 1f))
        bottom.addView(key(".") { typeOrSearch(".", searching) })
        bottom.addView(key(if (searching && giphyMode) "Search" else if (searching) "Done" else "↵") {
            if (searching && giphyMode) searchGiphy(false)
            else if (searching) { searchMode = false; render() }
            else {
                val action = currentInputEditorInfo?.imeOptions?.and(EditorInfo.IME_MASK_ACTION) ?: EditorInfo.IME_ACTION_NONE
                if (action != EditorInfo.IME_ACTION_NONE) currentInputConnection?.performEditorAction(action)
                else currentInputConnection?.commitText("\n", 1)
            }
        })
        rootView.addView(bottom)
    }

    private fun typeOrSearch(value: String, searching: Boolean) {
        if (searching) { search += value; render() } else currentInputConnection?.commitText(value, 1)
    }

    private fun notice(message: String) {
        updateStatus(message)
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    private fun updateStatus(message: String) {
        status = message
        statusView?.text = message
    }

    override fun onDestroy() {
        previewExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun row() = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }

    private fun label(text: String, size: Int, color: Int, bold: Boolean = false) = TextView(this).apply {
        this.text = text
        textSize = size.toFloat()
        setTextColor(color)
        gravity = Gravity.CENTER_VERTICAL
        maxLines = 1
        ellipsize = android.text.TextUtils.TruncateAt.END
        if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
        setPadding(dp(7), 0, dp(7), 0)
    }

    private fun key(text: String, selected: Boolean = false, action: () -> Unit) = TextView(this).apply {
        this.text = text
        textSize = 14f
        setTextColor(if (selected) this@MemlibKeyboardService.background else Color.WHITE)
        gravity = Gravity.CENTER
        background = rounded(if (selected) accent else panel, 10)
        setPadding(dp(9), 0, dp(9), 0)
        setOnClickListener { action() }
        val margin = dp(2)
        layoutParams = LinearLayout.LayoutParams(-2, dp(38)).apply { setMargins(margin, margin, margin, margin) }
    }

    private fun rounded(color: Int, radius: Int) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(radius).toFloat()
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}
