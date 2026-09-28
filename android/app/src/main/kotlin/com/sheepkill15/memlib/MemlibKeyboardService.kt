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
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.WindowInsets
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputContentInfo
import android.content.ClipDescription
import android.widget.HorizontalScrollView
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
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
    private data class Item(val id: String, val name: String, val filename: String, val folderId: String?, val favorite: Boolean, val uses: Int, val sourceType: String, val sourceId: String, val sourcePage: String?, val tags: List<String>)
    private data class Folder(val id: String, val name: String, val parentId: String?)
    private data class GiphyItem(val id: String, val title: String, val previewUrl: String, val gifUrl: String, val pageUrl: String,
        val onload: String?, val onclick: String?, val onsent: String?)

    // Mirrors lib/theme.dart (MemlibColors).
    private val background = Color.rgb(14, 12, 19)
    private val panel = Color.rgb(28, 24, 37)
    private val keyColor = Color.rgb(37, 32, 49)
    private val keyHigh = Color.rgb(47, 41, 64)
    private val accent = Color.rgb(189, 167, 255)
    private val accentDeep = Color.rgb(139, 104, 255)
    private val accentSoft = Color.argb(46, 189, 167, 255)
    private val accentLine = Color.argb(115, 189, 167, 255)
    private val onAccent = Color.rgb(23, 18, 42)
    private val textColor = Color.rgb(243, 241, 247)
    private val muted = Color.rgb(168, 162, 182)
    private val faint = Color.rgb(111, 105, 128)
    private val border = Color.rgb(52, 45, 66)
    private val hairline = Color.rgb(35, 30, 44)
    private val star = Color.rgb(255, 200, 87)
    private lateinit var rootView: LinearLayout
    private var libraryRoot: File? = null
    private var folders = emptyList<Folder>()
    private var items = emptyList<Item>()
    private var folderId: String? = null
    private var favorites = false
    private var search = ""
    private var searchMode = false
    private var tagFilterMode = false
    private val tagFilters = mutableSetOf<String>()
    private val draftTagFilters = mutableSetOf<String>()
    private var symbols = false
    private var shifted = false
    private var status = "Tap an item to send · hold to share"
    private var statusView: TextView? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val previewExecutor = Executors.newFixedThreadPool(3)
    private var previewGeneration = 0
    private var previewItemId: String? = null
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
            setPadding(dp(8), dp(6), dp(8), dp(8))
            setBackgroundColor(this@MemlibKeyboardService.background)
            setOnApplyWindowInsetsListener { view, insets ->
                val bottom = if (Build.VERSION.SDK_INT >= 30) {
                    insets.getInsets(WindowInsets.Type.navigationBars()).bottom
                } else {
                    @Suppress("DEPRECATION")
                    insets.systemWindowInsetBottom
                }
                view.setPadding(dp(8), dp(6), dp(8), maxOf(dp(8), bottom + dp(4)))
                insets
            }
        }
        window?.window?.navigationBarColor = background
        reloadLibrary()
        render()
        return rootView
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        reloadLibrary()
        status = "Tap an item to send · hold to share"
        tagFilterMode = false
        tagFilters.clear()
        draftTagFilters.clear()
        val variation = (info?.inputType ?: 0) and InputType.TYPE_MASK_VARIATION
        val password = variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
            variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
            variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD ||
            variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
        if (password) { searchMode = false; search = "" }
        if (::rootView.isInitialized) render()
    }

    private fun reloadLibrary() {
        val configured = getSharedPreferences("memlib_keyboard", MODE_PRIVATE).getString("library_root", null)
        val root = configured?.let(::File)?.canonicalFile
        libraryRoot = root?.takeIf { it.path.startsWith(filesDir.canonicalPath + File.separator) }
        try {
            val index = File(libraryRoot, "index.json")
            val data = JSONObject(index.readText())
            folders = data.optJSONArray("folders").asObjects().map { Folder(it.getString("id"), it.optString("name"), it.optNullableString("parentId")) }
            items = data.optJSONArray("items").asObjects().map {
                Item(it.getString("id"), it.optString("name"), it.getString("filename"), it.optNullableString("folderId"), it.optBoolean("favorite"), it.optInt("useCount"), it.optString("sourceType"), it.optString("sourceId"), it.optNullableString("sourcePage"), it.optJSONArray("tags").asStrings())
            }
            if (folderId != null && folders.none { it.id == folderId }) folderId = null
            val available = items.flatMap { it.tags }.map(String::lowercase).toSet()
            tagFilters.retainAll(available)
        } catch (_: Exception) {
            folders = emptyList()
            items = emptyList()
        }
    }

    private fun JSONArray?.asObjects(): List<JSONObject> =
        if (this == null) emptyList() else (0 until length()).mapNotNull { optJSONObject(it) }

    private fun JSONArray?.asStrings(): List<String> =
        if (this == null) emptyList() else (0 until length()).mapNotNull { optString(it).takeIf(String::isNotBlank) }

    private fun JSONObject.optNullableString(name: String): String? =
        (opt(name) as? String)?.takeIf(String::isNotEmpty)

    private fun render() {
        if (!::rootView.isInitialized) return
        previewGeneration++
        rootView.removeAllViews()
        statusView = null
        renderLibrary()
    }

    private fun renderLibrary() {
        previewItemId?.let { id ->
            val item = items.firstOrNull { it.id == id }
            if (item != null) {
                renderItemPreview(item)
                return
            }
            previewItemId = null
        }
        val hasGiphy = getSharedPreferences("memlib_keyboard", MODE_PRIVATE)
            .getString("giphy_key", "").orEmpty().isNotBlank()
        if (!hasGiphy) giphyMode = false
        val top = row()
        top.addView(brandMark(), LinearLayout.LayoutParams(dp(26), dp(26)).apply { setMargins(dp(4), 0, dp(8), 0) })
        val tabs = segmentGroup()
        tabs.addView(segment("Library", selected = !giphyMode, description = "Your library") {
            if (giphyMode) {
                giphyGeneration++
                giphyBusy = false
                giphyResults = emptyList()
                giphyHasMore = false
                giphyMode = false
                search = ""
                searchMode = false
                tagFilterMode = false
                render()
            }
        })
        if (hasGiphy) tabs.addView(segment("GIPHY", selected = giphyMode) {
            if (!giphyMode) { giphyMode = true; search = ""; searchMode = false; tagFilterMode = false; render() }
        })
        top.addView(tabs, LinearLayout.LayoutParams(-2, dp(34)))
        top.addView(View(this), LinearLayout.LayoutParams(0, dp(40), 1f))
        top.addView(ghostKey("↗", description = "Open Memlib library") { openLibrary() })
        top.addView(ghostKey("×", description = "Hide keyboard") { requestHideSelf(0) })
        rootView.addView(top, LinearLayout.LayoutParams(-1, dp(42)))

        val searchRow = row().apply {
            background = rounded(keyColor, 12, if (searchMode) accentLine else null)
            setPadding(dp(4), 0, dp(4), 0)
        }
        searchRow.addView(label("⌕", 20, if (searchMode) accent else muted))
        val searchText = if (search.isNotEmpty()) search else if (giphyMode) "Search GIPHY" else "Search items and tags"
        searchRow.addView(label(searchText, 14, if (search.isEmpty()) faint else textColor),
            LinearLayout.LayoutParams(0, dp(42), 1f))
        if (!giphyMode && !searchMode) searchRow.addView(pill(if (tagFilters.isEmpty()) "Tags" else "Tags (${tagFilters.size})",
            selected = tagFilterMode || tagFilters.isNotEmpty(), description = "Filter by tags") {
            if (tagFilterMode) tagFilterMode = false else {
                draftTagFilters.clear()
                draftTagFilters.addAll(tagFilters)
                tagFilterMode = true
            }
            render()
        })
        if (search.isNotEmpty()) searchRow.addView(ghostKey("×", description = "Clear search") { updateSearch("") })
        searchRow.setOnClickListener { view ->
            view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
            if (!searchMode) { tagFilterMode = false; searchMode = true; render() }
        }
        searchRow.isHapticFeedbackEnabled = true
        rootView.addView(searchRow, LinearLayout.LayoutParams(-1, dp(44)).apply {
            setMargins(dp(4), dp(2), dp(4), dp(6))
        })

        if (giphyMode && !searchMode) {
            val chips = row()
            val kinds = segmentGroup()
            kinds.addView(segment("GIFs", selected = !giphyStickers) { giphyStickers = false; if (search.isNotBlank()) searchGiphy(false) else render() })
            kinds.addView(segment("Stickers", selected = giphyStickers) { giphyStickers = true; if (search.isNotBlank()) searchGiphy(false) else render() })
            chips.addView(kinds, LinearLayout.LayoutParams(-2, dp(32)).apply { setMargins(dp(4), 0, 0, 0) })
            chips.addView(label("Powered by GIPHY", 11, faint).apply { gravity = Gravity.CENTER_VERTICAL or Gravity.END },
                LinearLayout.LayoutParams(0, dp(38), 1f))
            rootView.addView(chips)
        } else if (!searchMode && !tagFilterMode) {
            val folderScroll = HorizontalScrollView(this).apply { isHorizontalScrollBarEnabled = false }
            val chips = row()
            chips.setPadding(dp(2), 0, dp(2), 0)
            chips.addView(pill("All", selected = folderId == null && !favorites) { folderId = null; favorites = false; render() })
            chips.addView(pill("★ Favourites", selected = favorites) { folderId = null; favorites = true; render() })
            if (folderId != null) {
                val parent = folders.firstOrNull { it.id == folderId }?.parentId
                chips.addView(pill("↑ Up", description = "Go to parent folder") { folderId = parent; favorites = false; render() })
                folders.firstOrNull { it.id == folderId }?.let { chips.addView(label(it.name, 13, textColor, true)) }
            }
            folderScroll.addView(chips)
            rootView.addView(folderScroll, LinearLayout.LayoutParams(-1, dp(40)).apply { setMargins(0, 0, 0, dp(4)) })
        }

        val matching = items.asSequence()
            .filter { (search.isNotBlank() || it.folderId == folderId) && (!favorites || it.favorite) &&
                tagFilters.all { selected -> it.tags.any { tag -> tag.equals(selected, ignoreCase = true) } } &&
                (it.name.contains(search, ignoreCase = true) || it.tags.any { tag -> tag.contains(search, ignoreCase = true) }) }
            .sortedWith(compareBy<Item, String>(String.CASE_INSENSITIVE_ORDER) { it.name }.thenBy { it.id })
            .toList()
        val matchingFolders = if (search.isBlank() && !favorites && tagFilters.isEmpty()) {
            folders.filter { it.parentId == folderId }.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })
        } else emptyList()
        val scroller = ScrollView(this).apply { isFillViewport = true; isVerticalScrollBarEnabled = false }
        val grid = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(4), 0, dp(4), dp(4))
        }
        val gridFrame = FrameLayout(this)
        val loadIndicator = ProgressBar(this).apply {
            isIndeterminate = true
            visibility = View.GONE
        }
        val widthDp = resources.displayMetrics.widthPixels / resources.displayMetrics.density
        val columns = if (widthDp >= 520) 4 else 3
        val tileHeight = minOf(dp(128), (resources.displayMetrics.widthPixels - dp(28)) / columns)
        if (tagFilterMode) {
            renderTagFilters(grid)
        } else if (giphyMode && giphyResults.isNotEmpty()) {
            for (batch in giphyResults.chunked(columns)) {
                val line = row()
                for (item in batch) line.addView(giphyTile(item), LinearLayout.LayoutParams(0, tileHeight, 1f))
                repeat(columns - batch.size) { line.addView(View(this), LinearLayout.LayoutParams(0, 1, 1f)) }
                grid.addView(line)
            }
            if (giphyHasMore) grid.addView(pill("More GIPHY results") { searchGiphy(true) },
                LinearLayout.LayoutParams(-1, dp(38)).apply { setMargins(dp(3), dp(6), dp(3), dp(3)) })
        } else if (giphyMode) {
            grid.addView(emptyMessage(if (giphyBusy) "Searching GIPHY…" else "Type a reaction and press Search"),
                LinearLayout.LayoutParams(-1, dp(110)))
        } else if (matching.isEmpty() && matchingFolders.isEmpty()) {
            grid.addView(emptyMessage(if (items.isEmpty()) "Your library is empty. Open Memlib to add items." else "No matching stickers or GIFs"),
                LinearLayout.LayoutParams(-1, dp(110)))
        } else {
            for (batch in matchingFolders.chunked(columns)) {
                val folderLine = row()
                for (folder in batch) folderLine.addView(folderTile(folder), LinearLayout.LayoutParams(0, dp(56), 1f))
                repeat(columns - batch.size) { folderLine.addView(View(this), LinearLayout.LayoutParams(0, 1, 1f)) }
                grid.addView(folderLine)
            }
            var renderedItemCount = minOf(matching.size, columns * 2)
            appendLibraryItemRows(grid, matching, 0, renderedItemCount, columns, tileHeight)
            val virtualSpacer = View(this)
            fun updateVirtualSpacer() {
                val remainingRows = (matching.size - renderedItemCount + columns - 1) / columns
                virtualSpacer.layoutParams = LinearLayout.LayoutParams(-1, remainingRows * tileHeight)
                virtualSpacer.visibility = if (remainingRows == 0) View.GONE else View.VISIBLE
            }
            updateVirtualSpacer()
            grid.addView(virtualSpacer)
            var loadingMore = false
            scroller.setOnScrollChangeListener { _, _, scrollY, _, _ ->
                val loadedEnd = grid.height - virtualSpacer.height
                if (!loadingMore && renderedItemCount < matching.size &&
                    scrollY + scroller.height >= loadedEnd - dp(48)) {
                    loadingMore = true
                    loadIndicator.visibility = View.VISIBLE
                    mainHandler.post {
                        val nextCount = minOf(matching.size, renderedItemCount + columns * 2)
                        grid.removeView(virtualSpacer)
                        appendLibraryItemRows(grid, matching, renderedItemCount, nextCount, columns, tileHeight)
                        renderedItemCount = nextCount
                        updateVirtualSpacer()
                        grid.addView(virtualSpacer)
                        mainHandler.postDelayed({
                            loadIndicator.visibility = View.GONE
                            loadingMore = false
                        }, 180)
                    }
                }
            }
        }
        scroller.addView(grid)
        val gridHeight = if (searchMode) minOf(dp(94), resources.displayMetrics.heightPixels / 8)
            else minOf(dp(224), resources.displayMetrics.heightPixels / 3)
        gridFrame.addView(scroller, FrameLayout.LayoutParams(-1, -1))
        gridFrame.addView(loadIndicator, FrameLayout.LayoutParams(dp(22), dp(22), Gravity.BOTTOM or Gravity.RIGHT).apply {
            setMargins(0, 0, dp(8), dp(8))
        })
        rootView.addView(gridFrame, LinearLayout.LayoutParams(-1, gridHeight))
        if (searchMode) renderSearchKeys()
        if (!searchMode || giphyMode) {
            rootView.addView(View(this).apply { setBackgroundColor(hairline) }, LinearLayout.LayoutParams(-1, dp(1)).apply {
                setMargins(0, dp(4), 0, 0)
            })
            statusView = label(if (searchMode) "Powered by GIPHY" else if (tagFilterMode) "Items must match every selected tag" else status, 11, faint).apply {
                gravity = Gravity.CENTER
            }
            rootView.addView(statusView, LinearLayout.LayoutParams(-1, dp(22)))
        }
    }

    private fun appendLibraryItemRows(
        grid: LinearLayout,
        matching: List<Item>,
        start: Int,
        end: Int,
        columns: Int,
        tileHeight: Int
    ) {
        for (batch in matching.subList(start, end).chunked(columns)) {
            val line = row()
            for (item in batch) line.addView(tile(item), LinearLayout.LayoutParams(0, tileHeight, 1f))
            repeat(columns - batch.size) { line.addView(View(this), LinearLayout.LayoutParams(0, 1, 1f)) }
            grid.addView(line)
        }
    }

    private fun renderItemPreview(item: Item) {
        val top = row()
        top.addView(ghostKey("←", description = "Back to library") { previewItemId = null; render() })
        top.addView(label(item.name, 15, textColor, true), LinearLayout.LayoutParams(0, dp(42), 1f))
        rootView.addView(top)
        val file = File(File(libraryRoot, "media"), item.filename)
        val image = ImageView(this).apply {
            scaleType = ImageView.ScaleType.FIT_CENTER
            setPadding(dp(12), dp(12), dp(12), dp(12))
            background = rounded(panel, 14)
        }
        if (file.isFile) showFullPreview(image, file)
        rootView.addView(image, LinearLayout.LayoutParams(-1, 0, 1f).apply { setMargins(dp(4), dp(2), dp(4), dp(8)) })
        rootView.addView(key("Send", selected = true) { sendFile(file, item.id) }, LinearLayout.LayoutParams(-1, dp(46)).apply {
            setMargins(dp(4), 0, dp(4), 0)
        })
    }

    private fun renderTagFilters(container: LinearLayout) {
        val header = row()
        header.addView(label("Filter by tags", 14, textColor, true), LinearLayout.LayoutParams(0, dp(42), 1f))
        header.addView(ghostKey("Clear") { draftTagFilters.clear(); render() })
        header.addView(ghostKey("Cancel") { tagFilterMode = false; render() })
        header.addView(key("Apply", selected = true) {
            tagFilters.clear()
            tagFilters.addAll(draftTagFilters)
            tagFilterMode = false
            render()
        })
        container.addView(header)

        val tags = items.flatMap { it.tags }.distinctBy { it.lowercase() }
            .sortedWith(String.CASE_INSENSITIVE_ORDER)
        if (tags.isEmpty()) {
            container.addView(emptyMessage("No tags in your library"), LinearLayout.LayoutParams(-1, dp(100)))
            return
        }
        for (batch in tags.chunked(2)) {
            val line = row()
            for (tag in batch) {
                val normalized = tag.lowercase()
                lateinit var chip: TextView
                chip = pill(tag, selected = normalized in draftTagFilters) {
                    val selected = if (draftTagFilters.add(normalized)) true else {
                        draftTagFilters.remove(normalized)
                        false
                    }
                    chip.background = pillBackground(selected)
                    chip.setTextColor(if (selected) accent else textColor)
                    chip.contentDescription = "$tag ${if (selected) "selected" else "not selected"}"
                }
                chip.contentDescription = "$tag ${if (normalized in draftTagFilters) "selected" else "not selected"}"
                line.addView(chip, LinearLayout.LayoutParams(0, dp(42), 1f).apply {
                    setMargins(dp(2), dp(2), dp(2), dp(2))
                })
            }
            if (batch.size == 1) line.addView(View(this), LinearLayout.LayoutParams(0, 1, 1f))
            container.addView(line)
        }
    }

    private fun tile(item: Item): View {
        val outer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(panel, 12)
            clipToOutline = true
        }
        val file = File(File(libraryRoot, "media"), item.filename)
        val imageArea = FrameLayout(this)
        val preview = ImageView(this).apply {
            scaleType = ImageView.ScaleType.FIT_CENTER
            setPadding(dp(8), dp(8), dp(8), dp(2))
        }
        if (file.isFile) showPreview(preview, file)
        imageArea.addView(preview, FrameLayout.LayoutParams(-1, -1))
        imageArea.addView(overlayAction("⤢", "Preview ${item.name}") {
            previewItemId = item.id
            render()
        }, FrameLayout.LayoutParams(dp(24), dp(24), Gravity.BOTTOM or Gravity.RIGHT).apply { setMargins(0, 0, dp(5), dp(3)) })
        if (item.favorite) imageArea.addView(label("★", 15, star).apply { gravity = Gravity.CENTER; setPadding(0, 0, 0, 0) },
            FrameLayout.LayoutParams(dp(26), dp(26), Gravity.TOP or Gravity.RIGHT).apply { setMargins(0, dp(3), dp(3), 0) })
        if (item.sourceType == "giphy") imageArea.addView(label("GIPHY", 9, textColor, true).apply {
            background = rounded(Color.argb(204, 14, 12, 19), 6)
            setPadding(dp(5), 0, dp(5), 0)
        }, FrameLayout.LayoutParams(-2, dp(18), Gravity.BOTTOM or Gravity.LEFT).apply {
            setMargins(dp(6), 0, 0, dp(3))
        })
        outer.addView(imageArea, LinearLayout.LayoutParams(-1, 0, 1f))
        outer.addView(label(item.name, 11, muted), LinearLayout.LayoutParams(-1, dp(22)))
        outer.contentDescription = "${item.name}. Tap to send, hold to share"
        outer.isHapticFeedbackEnabled = true
        outer.setOnClickListener { view -> view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY); sendFile(file, item.id) }
        outer.setOnLongClickListener { shareFile(file); true }
        val holder = LinearLayout(this).apply { setPadding(dp(3), dp(3), dp(3), dp(3)); addView(outer, LinearLayout.LayoutParams(-1, -1)) }
        return holder
    }

    private fun giphyTile(item: GiphyItem): View {
        val outer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(panel, 12)
            clipToOutline = true
        }
        val imageArea = FrameLayout(this)
        val preview = ImageView(this).apply {
            scaleType = ImageView.ScaleType.FIT_CENTER
            setPadding(dp(7), dp(6), dp(7), dp(2))
        }
        giphyPreviews[item.id]?.let { showRemotePreview(preview, it) } ?: loadGiphyPreview(item, preview)
        imageArea.addView(preview, FrameLayout.LayoutParams(-1, -1))
        if (getSharedPreferences("memlib_keyboard", MODE_PRIVATE).getBoolean("allow_giphy_saves", false)) {
            val saved = items.firstOrNull { (it.sourceType == "giphy" && it.sourceId == item.id) || it.sourcePage == item.pageUrl }
            val pendingSave = isGiphySaveQueued(item)
            imageArea.addView(overlayAction(if (saved == null && !pendingSave) "+" else "✓", "Save to library") {
                if (saved == null && !pendingSave) queueGiphySave(item, favorite = false, toggle = false)
            }, FrameLayout.LayoutParams(dp(30), dp(30), Gravity.TOP or Gravity.RIGHT).apply { setMargins(0, dp(4), dp(4), 0) })
            val favourite = expectedGiphyFavorite(item, saved?.favorite == true)
            imageArea.addView(overlayAction(if (favourite) "★" else "☆", "Toggle favourite", if (favourite) star else textColor) {
                queueGiphySave(item, favorite = !expectedGiphyFavorite(item, saved?.favorite == true), toggle = true)
            }, FrameLayout.LayoutParams(dp(30), dp(30), Gravity.TOP or Gravity.LEFT).apply { setMargins(dp(4), dp(4), 0, 0) })
        }
        outer.addView(imageArea, LinearLayout.LayoutParams(-1, 0, 1f))
        outer.addView(label(item.title.ifBlank { "GIPHY" }, 11, muted), LinearLayout.LayoutParams(-1, dp(22)))
        outer.contentDescription = "${item.title.ifBlank { "GIPHY GIF" }}. Tap to send, hold to share"
        outer.isHapticFeedbackEnabled = true
        outer.setOnClickListener { view -> view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY); downloadGiphy(item, share = false) }
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
                    render()
                }
            } catch (error: Exception) {
                mainHandler.post {
                    if (generation != giphyGeneration) return@post
                    giphyBusy = false
                    render()
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

    private fun showFullPreview(view: ImageView, file: File) {
        val generation = previewGeneration
        previewExecutor.execute {
            val drawable: Drawable? = try {
                if (Build.VERSION.SDK_INT >= 28) {
                    ImageDecoder.decodeDrawable(ImageDecoder.createSource(file)) { decoder, info, _ ->
                        decoder.setTargetSampleSize(maxOf(1, maxOf(info.size.width, info.size.height) / 1200))
                    }
                } else BitmapFactory.decodeFile(file.path)?.let { BitmapDrawable(resources, it) }
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

    private fun renderSearchKeys() {
        val rows = if (symbols) listOf("1234567890", "@#\$%&-*+()", "!\"':;/?") else listOf("qwertyuiop", "asdfghjkl", "zxcvbnm")
        for ((index, letters) in rows.withIndex()) {
            val line = row()
            if (index == 2 && !symbols) line.addView(key(if (shifted) "⇧" else "↑", description = "Shift", modifier = true) { shifted = !shifted; render() },
                LinearLayout.LayoutParams(dp(46), dp(44)).apply { setMargins(dp(2), dp(3), dp(2), dp(3)) })
            for (char in letters) {
                val shown = if (shifted) char.uppercaseChar() else char
                val letter = key("$shown", letter = true) {
                    shifted = false
                    updateSearch(search + shown)
                }
                line.addView(letter, LinearLayout.LayoutParams(0, dp(44), 1f).apply {
                    setMargins(dp(2), dp(3), dp(2), dp(3))
                })
            }
            if (index == 2) line.addView(key("⌫", description = "Backspace", modifier = true) {
                if (search.isNotEmpty()) updateSearch(search.dropLast(1))
            }, LinearLayout.LayoutParams(dp(46), dp(44)).apply { setMargins(dp(2), dp(3), dp(2), dp(3)) })
            rootView.addView(line)
        }
        val bottom = row()
        fun bottomParams(width: Int) = LinearLayout.LayoutParams(dp(width), dp(44)).apply { setMargins(dp(2), dp(3), dp(2), dp(3)) }
        bottom.addView(key(if (symbols) "ABC" else "?123", modifier = true) { symbols = !symbols; render() }, bottomParams(58))
        bottom.addView(key(",", letter = true) { updateSearch(search + ",") }, bottomParams(38))
        bottom.addView(key("space") { updateSearch(search + " ") }, LinearLayout.LayoutParams(0, dp(44), 1f).apply {
            setMargins(dp(2), dp(3), dp(2), dp(3))
        })
        bottom.addView(key(".", letter = true) { updateSearch(search + ".") }, bottomParams(38))
        bottom.addView(key(if (giphyMode) "Search" else "Done", selected = true) {
            if (giphyMode) searchGiphy(false)
            else { searchMode = false; render() }
        }, bottomParams(76))
        rootView.addView(bottom)
    }

    private fun updateSearch(value: String) {
        search = value
        if (giphyMode) {
            giphyGeneration++
            giphyBusy = false
            giphyResults = emptyList()
            giphyHasMore = false
        }
        render()
    }

    private fun notice(message: String) {
        updateStatus(message)
    }

    private fun updateStatus(message: String) {
        status = message
        statusView?.text = message
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
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

    private fun emptyMessage(text: String) = label(text, 13, faint).apply {
        gravity = Gravity.CENTER
        maxLines = 2
        setPadding(dp(20), 0, dp(20), 0)
    }

    private fun key(
        text: String,
        selected: Boolean = false,
        description: String = text,
        letter: Boolean = false,
        modifier: Boolean = false,
        action: () -> Unit
    ) = TextView(this).apply {
        this.text = text
        contentDescription = description
        textSize = if (letter) 17f else 13f
        maxLines = 1
        ellipsize = android.text.TextUtils.TruncateAt.END
        setTextColor(if (selected) onAccent else if (modifier) muted else textColor)
        if (selected) setTypeface(typeface, android.graphics.Typeface.BOLD)
        gravity = Gravity.CENTER
        background = rounded(if (selected) accent else if (modifier) keyHigh else keyColor, 9)
        setPadding(dp(8), 0, dp(8), 0)
        isHapticFeedbackEnabled = true
        setOnClickListener { view ->
            view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
            action()
        }
        val margin = dp(2)
        layoutParams = LinearLayout.LayoutParams(-2, dp(34)).apply { setMargins(margin, margin, margin, margin) }
    }

    /** A borderless icon-like key used in toolbars. */
    private fun ghostKey(text: String, description: String = text, action: () -> Unit) = TextView(this).apply {
        this.text = text
        contentDescription = description
        textSize = if (text.length <= 2) 18f else 13f
        maxLines = 1
        setTextColor(muted)
        gravity = Gravity.CENTER
        background = rounded(Color.TRANSPARENT, 10)
        minWidth = dp(38)
        setPadding(dp(8), 0, dp(8), 0)
        isHapticFeedbackEnabled = true
        setOnClickListener { view ->
            view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
            action()
        }
        layoutParams = LinearLayout.LayoutParams(-2, dp(38)).apply { setMargins(dp(1), 0, dp(1), 0) }
    }

    private fun pillBackground(selected: Boolean) = GradientDrawable().apply {
        setColor(if (selected) accentSoft else Color.TRANSPARENT)
        cornerRadius = dp(16).toFloat()
        setStroke(dp(1), if (selected) accentLine else border)
    }

    /** A rounded filter chip: folders, favourites and tags. */
    private fun pill(text: String, selected: Boolean = false, description: String = text, action: () -> Unit) = TextView(this).apply {
        this.text = text
        contentDescription = description
        textSize = 13f
        maxLines = 1
        ellipsize = android.text.TextUtils.TruncateAt.END
        setTextColor(if (selected) accent else textColor)
        gravity = Gravity.CENTER
        background = pillBackground(selected)
        setPadding(dp(12), 0, dp(12), 0)
        isHapticFeedbackEnabled = true
        setOnClickListener { view ->
            view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
            action()
        }
        layoutParams = LinearLayout.LayoutParams(-2, dp(32)).apply { setMargins(dp(3), dp(4), dp(3), dp(4)) }
    }

    private fun segmentGroup() = row().apply {
        background = rounded(keyColor, 10)
        setPadding(dp(3), dp(3), dp(3), dp(3))
    }

    /** One option inside a [segmentGroup], e.g. Library / GIPHY. */
    private fun segment(text: String, selected: Boolean, description: String = text, action: () -> Unit) = TextView(this).apply {
        this.text = text
        contentDescription = description
        textSize = 13f
        maxLines = 1
        setTextColor(if (selected) textColor else muted)
        setTypeface(typeface, android.graphics.Typeface.BOLD)
        gravity = Gravity.CENTER
        background = rounded(if (selected) keyHigh else Color.TRANSPARENT, 7)
        setPadding(dp(12), 0, dp(12), 0)
        isHapticFeedbackEnabled = true
        setOnClickListener { view ->
            view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
            action()
        }
        layoutParams = LinearLayout.LayoutParams(-2, -1)
    }

    private fun brandMark() = TextView(this).apply {
        text = "✦"
        textSize = 13f
        gravity = Gravity.CENTER
        setTextColor(onAccent)
        background = GradientDrawable(GradientDrawable.Orientation.TL_BR, intArrayOf(accent, accentDeep)).apply {
            cornerRadius = dp(8).toFloat()
        }
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    private fun folderTile(folder: Folder): View {
        val count = items.count { it.folderId == folder.id }
        val outer = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = rounded(panel, 12)
            setPadding(dp(8), 0, dp(4), 0)
        }
        outer.addView(label("▣", 15, accent).apply {
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, 0)
            background = rounded(accentSoft, 8)
        }, LinearLayout.LayoutParams(dp(30), dp(30)))
        val text = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER_VERTICAL }
        text.addView(label(folder.name, 12, textColor, true))
        text.addView(label(if (count == 1) "1 item" else "$count items", 10, faint))
        outer.addView(text, LinearLayout.LayoutParams(0, -2, 1f))
        outer.contentDescription = "Open folder ${folder.name}"
        outer.isHapticFeedbackEnabled = true
        outer.setOnClickListener { view ->
            view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
            folderId = folder.id
            favorites = false
            render()
        }
        return LinearLayout(this).apply { setPadding(dp(3), dp(3), dp(3), dp(3)); addView(outer, LinearLayout.LayoutParams(-1, -1)) }
    }

    private fun overlayAction(text: String, description: String, color: Int = accent, action: () -> Unit) = TextView(this).apply {
        this.text = text
        contentDescription = description
        textSize = 15f
        gravity = Gravity.CENTER
        setTextColor(color)
        background = GradientDrawable().apply {
            setColor(Color.argb(204, 21, 18, 28))
            shape = GradientDrawable.OVAL
        }
        isHapticFeedbackEnabled = true
        setOnClickListener { view ->
            view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
            action()
        }
    }

    private fun rounded(color: Int, radius: Int, stroke: Int? = null) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(radius).toFloat()
        if (stroke != null) setStroke(dp(1), stroke)
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}
