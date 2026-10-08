package com.sheepkill15.memlib

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import org.json.JSONArray

class MainActivity : FlutterActivity() {
    private var androidChannel: MethodChannel? = null
    private val pendingImports = mutableListOf<String>()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val saved = JSONArray(getSharedPreferences("memlib_keyboard", MODE_PRIVATE).getString("pending_shared_images", "[]"))
        synchronized(pendingImports) { for (index in 0 until saved.length()) pendingImports.add(saved.getString(index)) }
        receiveImages(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        receiveImages(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "memlib/clipboard").setMethodCallHandler { call, result ->
            if (call.method != "copyFile") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val file = checkedAppFile(call.argument<String>("path"))
                val uri = providerUri(file)
                val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(ClipData.newUri(contentResolver, file.name, uri))
                result.success(null)
            } catch (error: Exception) {
                result.error("COPY_FAILED", error.message, null)
            }
        }
        androidChannel = MethodChannel(messenger, "memlib/android")
        androidChannel!!.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "setLibraryRoot" -> {
                        val root = File(call.argument<String>("path") ?: error("Missing path")).canonicalFile
                        require(root.path.startsWith(filesDir.canonicalPath + File.separator)) { "Library is outside app storage" }
                        getSharedPreferences("memlib_keyboard", MODE_PRIVATE).edit()
                            .putString("library_root", root.path)
                            .putString("giphy_key", call.argument<String>("giphyKey") ?: "")
                            .putBoolean("allow_giphy_saves", call.argument<Boolean>("allowGiphySaves") == true)
                            .apply()
                        result.success(null)
                    }
                    "drainSharedImages" -> {
                        synchronized(pendingImports) {
                            result.success(pendingImports.toList())
                        }
                    }
                    "ackSharedImages" -> {
                        val paths = call.argument<List<String>>("paths") ?: emptyList()
                        synchronized(pendingImports) {
                            pendingImports.removeAll(paths.toSet())
                            getSharedPreferences("memlib_keyboard", MODE_PRIVATE).edit()
                                .putString("pending_shared_images", JSONArray(pendingImports).toString()).apply()
                        }
                        result.success(null)
                    }
                    "drainUsedIds" -> {
                        val prefs = getSharedPreferences("memlib_keyboard", MODE_PRIVATE)
                        val queue = JSONArray(prefs.getString("used_ids", "[]"))
                        result.success((0 until queue.length()).map { queue.getString(it) })
                        prefs.edit().remove("used_ids").apply()
                    }
                    "drainGiphySaves" -> {
                        synchronized(MemlibKeyboardService::class.java) {
                            val prefs = getSharedPreferences("memlib_keyboard", MODE_PRIVATE)
                            val queue = JSONArray(prefs.getString("pending_giphy_saves", "[]"))
                            result.success((0 until queue.length()).map { index ->
                                val entry = queue.getJSONObject(index)
                                mapOf("id" to entry.getString("id"), "name" to entry.getString("name"),
                                    "sourcePage" to entry.getString("sourcePage"), "path" to entry.getString("path"),
                                    "favorite" to entry.getBoolean("favorite"), "toggle" to entry.getBoolean("toggle"),
                                    "sticker" to entry.optBoolean("sticker"))
                            })
                        }
                    }
                    "ackGiphySave" -> {
                        val path = call.argument<String>("path") ?: error("Missing path")
                        synchronized(MemlibKeyboardService::class.java) {
                            val prefs = getSharedPreferences("memlib_keyboard", MODE_PRIVATE)
                            val queue = JSONArray(prefs.getString("pending_giphy_saves", "[]"))
                            val remaining = JSONArray()
                            for (index in 0 until queue.length()) {
                                val entry = queue.getJSONObject(index)
                                if (entry.getString("path") != path) remaining.put(entry)
                            }
                            prefs.edit().putString("pending_giphy_saves", remaining.toString()).apply()
                        }
                        result.success(null)
                    }
                    "openKeyboardSettings" -> {
                        startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
                        result.success(null)
                    }
                    "showKeyboardPicker" -> {
                        (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).showInputMethodPicker()
                        result.success(null)
                    }
                    "importClipboardImage" -> {
                        val clips = (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).primaryClip
                        val uris = mutableListOf<Uri>()
                        if (clips != null) for (index in 0 until clips.itemCount) clips.getItemAt(index).uri?.let(uris::add)
                        require(uris.isNotEmpty()) { "Clipboard has no image file" }
                        queueUris(uris)
                        result.success(null)
                    }
                    "shareFile" -> {
                        val file = checkedAppFile(call.argument<String>("path"))
                        val uri = providerUri(file)
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = mediaType(file)
                            putExtra(Intent.EXTRA_STREAM, uri)
                            clipData = ClipData.newUri(contentResolver, file.name, uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(Intent.createChooser(send, "Share sticker or GIF"))
                        result.success(null)
                    }
                    "installApk" -> {
                        val file = checkedAppFile(call.argument<String>("path"))
                        require(file.extension.equals("apk", ignoreCase = true)) { "Update file is not an APK" }
                        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O &&
                            !packageManager.canRequestPackageInstalls()) {
                            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                                data = Uri.parse("package:$packageName")
                            })
                            result.success(false)
                        } else {
                            val install = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(providerUri(file), "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(install)
                            result.success(true)
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("ANDROID_ACTION_FAILED", error.message, null)
            }
        }
    }

    private fun checkedAppFile(path: String?): File {
        val file = File(path ?: error("Missing path")).canonicalFile
        val inFiles = file.path.startsWith(filesDir.canonicalPath + File.separator)
        val inCache = file.path.startsWith(cacheDir.canonicalPath + File.separator)
        require((inFiles || inCache) && file.isFile) { "File is outside app storage" }
        return file
    }

    private fun providerUri(file: File): Uri =
        FileProvider.getUriForFile(this, "$packageName.provider", file)

    private fun mediaType(file: File): String = when (file.extension.lowercase()) {
        "gif" -> "image/gif"
        "png" -> "image/png"
        "webp" -> "image/webp"
        else -> "image/jpeg"
    }

    private fun receiveImages(source: Intent?) {
        if (source?.action != Intent.ACTION_SEND && source?.action != Intent.ACTION_SEND_MULTIPLE) return
        val uris = mutableListOf<Uri>()
        source.clipData?.let { clips ->
            for (index in 0 until clips.itemCount) clips.getItemAt(index).uri?.let(uris::add)
        }
        @Suppress("DEPRECATION")
        if (source.action == Intent.ACTION_SEND) {
            source.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let(uris::add)
        } else {
            source.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let(uris::addAll)
        }
        if (uris.isEmpty()) return
        queueUris(uris)
    }

    private fun queueUris(uris: List<Uri>) {
        Thread {
            for (uri in uris.distinct()) {
                try {
                    val path = copySharedImage(uri) ?: continue
                    synchronized(pendingImports) {
                        pendingImports.add(path)
                        getSharedPreferences("memlib_keyboard", MODE_PRIVATE).edit()
                            .putString("pending_shared_images", JSONArray(pendingImports).toString()).apply()
                    }
                    mainHandler.post { androidChannel?.invokeMethod("sharedImagesReady", null) }
                } catch (_: Exception) { /* A revoked or malformed share must not crash the app. */ }
            }
        }.start()
    }

    private fun copySharedImage(uri: Uri): String? {
        val suppliedName = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
        val extension = suppliedName?.substringAfterLast('.', "")?.lowercase()
        val mime = contentResolver.getType(uri)
        val cleanExtension = when {
            extension in setOf("gif", "png", "jpg", "jpeg", "webp") -> extension!!
            mime == "image/gif" -> "gif"
            mime == "image/png" -> "png"
            mime == "image/webp" -> "webp"
            mime == "image/jpeg" -> "jpg"
            else -> return null
        }
        val base = suppliedName?.substringBeforeLast('.')?.replace(Regex("[^A-Za-z0-9 _.-]"), "_")?.take(80)
            ?.ifBlank { "Shared image" } ?: "Shared image"
        val folder = File(cacheDir, "shared-imports/${UUID.randomUUID()}")
        folder.mkdirs()
        val target = File(folder, "$base.$cleanExtension")
        try {
            val inputStream = contentResolver.openInputStream(uri) ?: error("Shared image is unavailable")
            inputStream.use { input ->
                target.outputStream().use { output ->
                    val buffer = ByteArray(32 * 1024)
                    var count = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        count += read
                        require(count <= 30L * 1024 * 1024) { "Shared image is too large" }
                        output.write(buffer, 0, read)
                    }
                }
            }
            return target.path
        } catch (error: Exception) {
            target.delete()
            folder.delete()
            throw error
        }
    }
}
