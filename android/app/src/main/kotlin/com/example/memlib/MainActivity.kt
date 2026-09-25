package com.example.memlib

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "memlib/clipboard")
            .setMethodCallHandler { call, result ->
                if (call.method != "copyFile") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val path = call.argument<String>("path") ?: error("Missing path")
                    val file = File(path).canonicalFile
                    val inFiles = file.path.startsWith(filesDir.canonicalPath + File.separator)
                    val inCache = file.path.startsWith(cacheDir.canonicalPath + File.separator)
                    require((inFiles || inCache) && file.isFile) { "File is outside app storage" }
                    val uri = FileProvider.getUriForFile(this, "$packageName.provider", file)
                    val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    clipboard.setPrimaryClip(ClipData.newUri(contentResolver, file.name, uri))
                    result.success(null)
                } catch (error: Exception) {
                    result.error("COPY_FAILED", error.message, null)
                }
            }
    }
}
