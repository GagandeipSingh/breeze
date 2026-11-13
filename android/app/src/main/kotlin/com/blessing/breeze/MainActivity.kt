package com.blessing.breeze

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth for
// the biometric prompt to attach to a FragmentActivity.
class MainActivity : FlutterFragmentActivity() {
    private val channel = "breeze/open"

    // The file the user tapped to launch us (VIEW/EDIT), read as text and held
    // until Flutter asks for it. content:// URIs can't be opened by path, so we
    // read the bytes here and hand over name + text.
    private var pendingName: String? = null
    private var pendingText: String? = null
    // Set for a PICKED document whose answer arrived after Android recreated
    // the app (the picker's own call died with the old engine), and for a
    // tapped file the other app let Breeze write: either opens as the
    // original file, so saves go back to it.
    private var pendingUri: String? = null
    private var pendingCharset: String? = null
    // A tapped file the other app let Breeze read only: it opens as a copy,
    // and Breeze says so.
    private var pendingCopy = false
    // Flutter has already asked for a launch file, so anything arriving
    // later must be pushed to it.
    private var dartAsked = false

    private fun pendingMap(): Map<String, String?> = mapOf(
        "name" to pendingName,
        "content" to pendingText,
        "uri" to pendingUri,
        "charset" to pendingCharset,
        "copy" to (if (pendingCopy) "1" else null),
    )

    private fun clearPending() {
        pendingName = null
        pendingText = null
        pendingUri = null
        pendingCharset = null
        pendingCopy = false
    }
    private var methodChannel: MethodChannel? = null

    // "Open file" goes through the system document picker so the user's
    // ORIGINAL file is edited. file_picker handed back a cache copy, so every
    // save landed in that copy and the real file never changed.
    private var pickResult: MethodChannel.Result? = null
    private val pickRequest = 4711
    private var saveResult: MethodChannel.Result? = null
    private var savePath: String? = null
    private val saveRequest = 4712
    private val io = java.util.concurrent.Executors.newSingleThreadExecutor()
    // PDFs get their own thread: a long one must not hold up saving.
    private val pdfThread = java.util.concurrent.Executors.newSingleThreadExecutor()

    /** [text] in the document's own encoding [name] (as readDoc named it).
     *  UTF-16 keeps its byte order and mark (Charsets.UTF_16 always wrote
     *  big-endian, flipping a Windows file on every save), and text Latin-1
     *  cannot hold is written as UTF-8 instead of being lost as '?'. */
    private val CP1252 = java.nio.charset.Charset.forName("windows-1252")

    private fun encodeDoc(text: String, name: String?): ByteArray = when (name) {
        // Text it cannot hold goes UTF-8, from real characters, so the
        // file's quotes and euro signs stay right.
        "windows-1252" ->
            if (CP1252.newEncoder().canEncode(text)) text.toByteArray(CP1252)
            else text.toByteArray(Charsets.UTF_8)
        "ISO-8859-1" ->
            if (Charsets.ISO_8859_1.newEncoder().canEncode(text)) text.toByteArray(Charsets.ISO_8859_1)
            else text.toByteArray(Charsets.UTF_8)
        "UTF-16LE" -> byteArrayOf(0xFF.toByte(), 0xFE.toByte()) + text.toByteArray(Charsets.UTF_16LE)
        "UTF-16BE", "UTF-16" -> byteArrayOf(0xFE.toByte(), 0xFF.toByte()) + text.toByteArray(Charsets.UTF_16BE)
        else -> text.toByteArray(Charsets.UTF_8)
    }

    /** Replace a document's bytes. "wt" truncates; a provider that refuses
     *  it gets a descriptor truncated by hand, so a shorter save never
     *  leaves the old file's tail behind. */
    private fun writeDoc(uri: Uri, bytes: ByteArray) {
        // "wt" empties the document the moment it opens, so a write that
        // fails part-way would leave the user's own file blank (and the
        // editor then offers Discard). Its old bytes are kept to put back.
        val before = try {
            contentResolver.openInputStream(uri)?.use { input ->
                val buf = java.io.ByteArrayOutputStream()
                val chunk = ByteArray(64 * 1024)
                var total = 0
                var tooBig = false
                while (true) {
                    val n = input.read(chunk)
                    if (n < 0) break
                    total += n
                    if (total > 25 * 1024 * 1024) {
                        tooBig = true
                        break
                    }
                    buf.write(chunk, 0, n)
                }
                if (tooBig) null else buf.toByteArray()
            }
        } catch (_: Exception) {
            null
        }
        try {
            replaceDoc(uri, bytes)
        } catch (e: Exception) {
            if (before != null) {
                try {
                    replaceDoc(uri, before)
                } catch (_: Exception) {
                }
            }
            throw e
        }
    }

    private fun replaceDoc(uri: Uri, bytes: ByteArray) {
        try {
            contentResolver.openOutputStream(uri, "wt").use { out ->
                if (out == null) throw IllegalStateException("no stream")
                out.write(bytes)
            }
        } catch (e: Exception) {
            val pfd = contentResolver.openFileDescriptor(uri, "rw") ?: throw e
            pfd.use {
                java.io.FileOutputStream(it.fileDescriptor).use { fos ->
                    fos.channel.truncate(0)
                    fos.write(bytes)
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel).apply {
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        "getOpenedFile" -> {
                            dartAsked = true
                            if (pendingText != null) {
                                result.success(pendingMap())
                                clearPending()
                            } else {
                                result.success(null)
                            }
                        }
                        // Time since boot, which moving the clock cannot change
                        // (the PIN wait is measured with it).
                        "uptime" -> result.success(android.os.SystemClock.elapsedRealtime())
                        // A link tapped in a note (web, mail, phone only; Dart
                        // checks the scheme too). False when nothing opens it.
                        "openUrl" -> {
                            val url = call.argument<String>("url")
                            val uri = url?.let { Uri.parse(it) }
                            val scheme = uri?.scheme?.lowercase()
                            if (uri == null || scheme !in setOf("http", "https", "mailto", "tel")) {
                                result.success(false)
                            } else {
                                val action = if (scheme == "tel") Intent.ACTION_DIAL else Intent.ACTION_VIEW
                                try {
                                    startActivity(Intent(action, uri).addCategory(Intent.CATEGORY_BROWSABLE))
                                    result.success(true)
                                } catch (_: Exception) {
                                    result.success(false)
                                }
                            }
                        }
                        "pickDocument" -> {
                            pickResult?.error("busy", "picker already open", null)
                            pickResult = result
                            val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                                addFlags(
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                                )
                            }
                            @Suppress("DEPRECATION")
                            startActivityForResult(i, pickRequest)
                        }
                        // A recent file, read again from where it lives.
                        "readUri" -> {
                            val uri = Uri.parse(call.argument<String>("uri"))
                            io.execute {
                                try {
                                    val (text, cs) = readDoc(uri)
                                    val name = displayName(uri)
                                    runOnUiThread {
                                        result.success(
                                            mapOf("uri" to uri.toString(), "name" to name, "content" to text, "charset" to cs)
                                        )
                                    }
                                } catch (e: Exception) {
                                    // Only a missing file or lost access is "gone" (Breeze then
                                    // drops it from Recent). Anything else, like a cloud file
                                    // read offline, may work later, so it is kept.
                                    val gone = e is java.io.FileNotFoundException ||
                                        e is SecurityException
                                    runOnUiThread {
                                        result.error(if (gone) "gone" else "failed", e.message, null)
                                    }
                                }
                            }
                        }
                        // A file taken off the recent list: its lasting
                        // access is given back.
                        "forgetUri" -> {
                            try {
                                val uri = Uri.parse(call.argument<String>("uri"))
                                val held = contentResolver.persistedUriPermissions.firstOrNull { it.uri == uri }
                                if (held != null) {
                                    var flags = 0
                                    if (held.isReadPermission) flags = flags or Intent.FLAG_GRANT_READ_URI_PERMISSION
                                    if (held.isWritePermission) flags = flags or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                                    contentResolver.releasePersistableUriPermission(uri, flags)
                                }
                            } catch (_: Exception) {
                            }
                            result.success(null)
                        }
                        // Where a file opened from elsewhere lives, in words
                        // ("Internal storage › Download"), and whether its
                        // folder can be opened in a file manager.
                        "locate" -> {
                            val uri = Uri.parse(call.argument<String>("uri"))
                            result.success(mapOf("where" to whereIs(uri), "canShow" to (folderOf(uri) != null)))
                        }
                        // Opens the folder holding [uri] in the phone's file
                        // manager. False when no app can show it.
                        "showInFiles" -> {
                            val uri = Uri.parse(call.argument<String>("uri"))
                            result.success(showFolder(uri))
                        }
                        // A copy of one of Breeze's own files, saved where the
                        // user picks, byte for byte (a Word file stays one).
                        "saveCopy" -> {
                            saveResult?.error("busy", "save already open", null)
                            saveResult = result
                            savePath = call.argument<String>("path")
                            val name = call.argument<String>("name") ?: "File.txt"
                            val ext = name.substringAfterLast('.', "").lowercase()
                            val mime = android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
                                ?: "application/octet-stream"
                            val i = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = mime
                                putExtra(Intent.EXTRA_TITLE, name)
                            }
                            try {
                                @Suppress("DEPRECATION")
                                startActivityForResult(i, saveRequest)
                            } catch (_: Exception) {
                                saveResult = null
                                result.success(false)
                            }
                        }
                        "writeDocument" -> {
                            val uri = Uri.parse(call.argument<String>("uri"))
                            val text = call.argument<String>("content") ?: ""
                            val cs = call.argument<String>("charset")
                            // Off the UI thread: autosave writes the whole
                            // document, which on a cloud provider can take
                            // seconds.
                            io.execute {
                                try {
                                    writeDoc(uri, encodeDoc(text, cs))
                                    runOnUiThread { result.success(true) }
                                } catch (e: Exception) {
                                    runOnUiThread { result.error("write", e.message, null) }
                                }
                            }
                        }
                        // A note as a PDF, laid out by Android (PdfMaker.kt).
                        "makePdf" -> {
                            @Suppress("UNCHECKED_CAST")
                            val paras = call.argument<List<List<Any?>>>("paras") ?: emptyList()
                            val code = call.argument<Boolean>("code") ?: false
                            pdfThread.execute {
                                try {
                                    val dir = java.io.File(cacheDir, "pdf_native")
                                    // Dart deletes each PDF once read; this only clears
                                    // ones a crash left behind, never one still in use.
                                    val stale = System.currentTimeMillis() - 10 * 60 * 1000
                                    dir.listFiles()?.forEach { if (it.lastModified() < stale) it.delete() }
                                    val out = java.io.File(dir, "${System.nanoTime()}.pdf")
                                    PdfMaker(applicationContext).make(paras, code, out)
                                    runOnUiThread { result.success(out.path) }
                                } catch (e: Throwable) {
                                    runOnUiThread { result.error("pdf", e.toString(), null) }
                                }
                            }
                        }
                        // FLAG_SECURE while a locked note is open: no
                        // recent-apps preview, no screenshots of it.
                        "secure" -> {
                            if (call.arguments == true) {
                                window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
                            } else {
                                window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
                            }
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }
            }
        // A recreated activity (theme change, process restored, reopened from
        // recents) still carries the launch intent, and reading it again
        // imported the same file as "notes 2.json", "notes 3.json", ...
        if (savedInstanceState == null &&
            (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) == 0
        ) {
            receive(intent)
        }
        consume(intent)
    }

    /**
     * Reads a tapped, shared or selected file OFF the main thread (a file
     * from a cloud app can take seconds, which froze the app), then hands it
     * to Flutter if it is already listening, or keeps it until it asks.
     *
     * Each arrival replaces what was waiting, all of it: a shared text left
     * beside an earlier picked file's uri would have been saved over that
     * file.
     */
    private fun receive(intent: Intent?) {
        if (intent == null) return
        // consume() blanks the original once this returns.
        val copy = Intent(intent)
        io.execute {
            // Every failure says why: a tap that silently did nothing read
            // as Breeze being broken.
            var why: String? = null
            var editable: Pair<String, String>? = null
            val got = try {
                editable = writableOrigin(copy)
                readIntent(copy)
            } catch (e: OpenFail) {
                why = e.message
                null
            } catch (e: Exception) {
                why = if (e.message == "too large") "This file is too large to open (over 20 MB)"
                else "Couldn't open this file"
                null
            } catch (_: OutOfMemoryError) {
                why = "This file is too large to open"
                null
            }
            runOnUiThread {
                if (got == null) {
                    if (why != null) {
                        android.widget.Toast.makeText(this, why, android.widget.Toast.LENGTH_LONG).show()
                    }
                    return@runOnUiThread
                }
                clearPending()
                pendingName = got.first
                pendingText = got.second
                // Writable: it opens as the ORIGINAL file, so saves reach
                // it; otherwise Breeze keeps a copy.
                pendingUri = editable?.first
                pendingCharset = editable?.second ?: got.third
                pendingCopy = editable == null &&
                    (copy.action == Intent.ACTION_VIEW || copy.action == Intent.ACTION_EDIT)
                if (dartAsked) {
                    methodChannel?.invokeMethod("openFile", pendingMap())
                    clearPending()
                }
            }
        }
    }

    private var savedInstanceState: android.os.Bundle? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        this.savedInstanceState = savedInstanceState
        super.onCreate(savedInstanceState)
    }

    /** Marks a VIEW/EDIT intent as handled, so nothing reads it twice. */
    private fun consume(intent: Intent?) {
        if (intent?.action == Intent.ACTION_VIEW || intent?.action == Intent.ACTION_EDIT ||
            intent?.action == Intent.ACTION_SEND || intent?.action == Intent.ACTION_PROCESS_TEXT
        ) {
            intent.action = Intent.ACTION_MAIN
            intent.data = null
            intent.removeExtra(Intent.EXTRA_TEXT)
            intent.removeExtra(Intent.EXTRA_STREAM)
            intent.removeExtra(Intent.EXTRA_PROCESS_TEXT)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        receive(intent)
        consume(intent)
    }

    /** (name, text) of what an intent brings, or null. Runs on [io]. */
    private fun readIntent(intent: Intent): Triple<String?, String, String?>? {
        if (intent.action == Intent.ACTION_SEND) return readShare(intent)
        if (intent.action == Intent.ACTION_PROCESS_TEXT) {
            // Selected text in another app -> "New Breeze note".
            val t = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
            if (t.isNullOrBlank()) throw OpenFail("Nothing to open: the text is empty")
            return readShare(Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_TEXT, t))
        }
        if (intent.action != Intent.ACTION_VIEW && intent.action != Intent.ACTION_EDIT) return null
        val uri = intent.data ?: throw OpenFail("Couldn't open this file")
        if (uri.scheme == "file" && isPrivate(uri)) throw OpenFail("Breeze can't open this file")
        // Decoded by its real encoding: a Latin-1 file read as UTF-8 became
        // U+FFFD characters in the copy.
        // With its encoding: a Word document's bytes come back from it.
        val (text, cs) = readDoc(uri)
        return Triple(namedFor(displayName(uri), text), text, cs)
    }

    /** (uri, encoding) of a tapped file that Breeze may write back to, or
     *  null. Only a file the other app granted WRITE access to (or an
     *  ordinary writable file:// path) qualifies; anything else opens as a
     *  copy, since a save there would fail. */
    private fun writableOrigin(intent: Intent): Pair<String, String>? {
        if (intent.action != Intent.ACTION_VIEW && intent.action != Intent.ACTION_EDIT) return null
        val uri = intent.data ?: return null
        val ok = when (uri.scheme) {
            "content" -> checkUriPermission(
                uri, android.os.Process.myPid(), android.os.Process.myUid(),
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED && supportsWrite(uri)
            "file" -> !isPrivate(uri) && uri.path?.let { java.io.File(it).canWrite() } == true
            else -> false
        }
        if (!ok) return null
        if (uri.scheme == "content") {
            // Kept past a restart where the other app allows it.
            try {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
            } catch (_: Exception) {
            }
        }
        // Unknown encoding: open as a copy. Guessing UTF-8 would re-encode
        // every accented letter of a Latin-1 file on the first save.
        val charset = try { readDoc(uri).second } catch (_: Exception) { return null }
        return Pair(uri.toString(), charset)
    }

    /** A file:// link into Breeze's own storage (its notes, locked ones and
     *  the trash included, its settings and PIN hash). Opening one would copy
     *  a private file into a new, unlocked note, so it is refused; file://
     *  links to ordinary phone storage still open. */
    private fun isPrivate(uri: Uri): Boolean {
        val path = uri.path ?: return true
        val target = try {
            java.io.File(path).canonicalPath
        } catch (_: Exception) {
            return true
        }
        val roots = listOfNotNull(
            applicationInfo.dataDir,
            filesDir.parentFile?.path,
            createDeviceProtectedStorageContext().dataDir?.path,
            "/data/data/$packageName",
            "/data/user/0/$packageName",
        )
        return roots.any { root ->
            val r = try { java.io.File(root).canonicalPath } catch (_: Exception) { root }
            target == r || target.startsWith(r + java.io.File.separator)
        }
    }

    /** Shared from another app: a text file (EXTRA_STREAM) keeps its name;
     *  plain text (EXTRA_TEXT) is named after its subject or first line. */
    private fun readShare(intent: Intent): Triple<String?, String, String?>? {
        @Suppress("DEPRECATION")
        val stream = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        if (stream != null) {
            // A file:// link could point at Breeze's own private files (its
            // PIN among them) and copy them into a note.
            if (stream.scheme != "content") throw OpenFail("Breeze can't open this file")
            val (text, cs) = readDoc(stream)
            return Triple(namedFor(displayName(stream), text), text, cs)
        }
        run {
            val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            if (text.isNullOrBlank()) throw OpenFail("Nothing to open: the text is empty")
            val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
            val firstWords = text.trim().split(Regex("\\s+")).take(3).joinToString(" ")
            val base = (if (!subject.isNullOrBlank()) subject else firstWords)
                .replace(Regex("[\\\\/:*?\"<>|]"), " ")
                .replace(Regex("\\s+"), " ")
                .trim()
                .take(40)
                .trim()
            return Triple((if (base.isEmpty()) "Shared note" else base) + ".txt", text, null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == saveRequest) {
            val r = saveResult
            val path = savePath
            saveResult = null
            savePath = null
            val dest = data?.data
            if (r == null) {
                // Breeze was closed while the picker was open, so what was to
                // be saved is gone; do not leave the empty file it made.
                if (resultCode == RESULT_OK && dest != null) {
                    io.execute { deleteIfEmpty(dest) }
                }
                return
            }
            if (resultCode != RESULT_OK || dest == null || path == null) {
                r.success(null)
                return
            }
            io.execute {
                fun copy(mode: String) {
                    contentResolver.openOutputStream(dest, mode).use { out ->
                        if (out == null) throw IllegalStateException("no stream")
                        java.io.File(path).inputStream().use { it.copyTo(out) }
                    }
                }
                val ok = try {
                    // "wt" truncates; a provider that refuses it gets "w",
                    // which is safe here because the document was just made.
                    try { copy("wt") } catch (_: IllegalArgumentException) { copy("w") }
                    true
                } catch (_: Exception) {
                    // The picker may have made the file: do not leave an
                    // empty copy behind (a file the user chose to replace
                    // still has its bytes, and is kept).
                    deleteIfEmpty(dest)
                    false
                }
                // The copy's address on success, so Breeze can show its folder.
                runOnUiThread { r.success(if (ok) dest.toString() else false) }
            }
            return
        }
        if (requestCode != pickRequest) return
        val result = pickResult
        pickResult = null
        val uri = data?.data
        if (result == null) {
            // Android recreated the app while the picker was open, so the
            // call that asked for this is gone. Open the file anyway.
            if (resultCode == RESULT_OK && uri != null) adoptLostPick(uri)
            return
        }
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        keepAccess(uri)
        // A provider that gave read access only: saving there would fail on
        // every autosave, so Breeze is told and opens it as a copy.
        val writable = checkUriPermission(
            uri, android.os.Process.myPid(), android.os.Process.myUid(),
            Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED && supportsWrite(uri)
        io.execute {
            try {
                val (text, cs) = readDoc(uri)
                val name = displayName(uri)
                runOnUiThread {
                    result.success(
                        mapOf(
                            "uri" to uri.toString(), "name" to name, "content" to text,
                            "charset" to cs, "writable" to writable,
                        )
                    )
                }
            } catch (e: Exception) {
                runOnUiThread { result.error("read", e.message, null) }
            }
        }
    }

    /** Whether the provider says this document can be written. The picker
     *  grants the write flag it was asked for even where the provider
     *  (Drive, Photos) cannot save, so the flag alone does not tell. When
     *  the provider gives no flags, it is trusted. */
    private fun supportsWrite(uri: Uri): Boolean = try {
        contentResolver.query(
            uri, arrayOf(android.provider.DocumentsContract.Document.COLUMN_FLAGS),
            null, null, null,
        )?.use { c ->
            val i = c.getColumnIndex(android.provider.DocumentsContract.Document.COLUMN_FLAGS)
            if (i < 0 || !c.moveToFirst() || c.isNull(i)) true
            else c.getInt(i) and android.provider.DocumentsContract.Document.FLAG_SUPPORTS_WRITE != 0
        } ?: true
    } catch (_: Exception) {
        true
    }

    /** Deletes a document the save picker made, only when it is still
     *  empty: a file the user picked to replace keeps its bytes. */
    private fun deleteIfEmpty(uri: Uri) {
        try {
            val size = contentResolver.query(
                uri, arrayOf(android.provider.OpenableColumns.SIZE), null, null, null,
            )?.use { c ->
                val i = c.getColumnIndex(android.provider.OpenableColumns.SIZE)
                if (i >= 0 && c.moveToFirst() && !c.isNull(i)) c.getLong(i) else null
            }
            if (size == 0L) {
                android.provider.DocumentsContract.deleteDocument(contentResolver, uri)
            }
        } catch (_: Exception) {}
    }

    /** Keeps access to a picked file past a restart, so it can be opened
     *  again from the recent list: read and write where the provider
     *  allows, else read only. */
    private fun keepAccess(uri: Uri) {
        try {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        } catch (_: Exception) {
            try {
                contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (_: Exception) {
            }
        }
    }

    /** The document id of [uri] on the phone's own storage provider
     *  ("primary:Download/notes.md"), or null for any other place. A file
     *  picked under Downloads or a media category comes from another
     *  provider with an opaque id ("document:1000016509"); MediaStore
     *  knows its folder, so it is found there. */
    private fun storageDocId(uri: Uri): String? {
        if (uri.authority == "com.android.externalstorage.documents") {
            return try {
                android.provider.DocumentsContract.getDocumentId(uri)
            } catch (_: Exception) {
                null
            }
        }
        return mediaStoreDocId(uri) ?: rawPathDocId(uri)
    }

    /** Downloads hands out "raw:/storage/emulated/0/Download/x" ids on
     *  some phones: the path is right there. */
    private fun rawPathDocId(uri: Uri): String? {
        if (uri.authority != "com.android.providers.downloads.documents") return null
        val id = try {
            android.provider.DocumentsContract.getDocumentId(uri)
        } catch (_: Exception) {
            return null
        }
        if (!id.startsWith("raw:")) return null
        val rel = id.removePrefix("raw:").removePrefix("/storage/emulated/0/")
        return if (rel.startsWith("/")) null else "primary:$rel"
    }

    /** The storage id of a Downloads or media document, read from
     *  MediaStore's own record of where the file sits (Android 10+). */
    private fun mediaStoreDocId(uri: Uri): String? {
        if (android.os.Build.VERSION.SDK_INT < 29) return null
        val auth = uri.authority
        if (auth != "com.android.providers.media.documents" &&
            auth != "com.android.providers.downloads.documents"
        ) return null
        return try {
            val media = android.provider.MediaStore.getMediaUri(this, uri) ?: return null
            val cols = arrayOf(
                android.provider.MediaStore.MediaColumns.RELATIVE_PATH,
                android.provider.MediaStore.MediaColumns.VOLUME_NAME,
                android.provider.MediaStore.MediaColumns.DISPLAY_NAME,
            )
            contentResolver.query(media, cols, null, null, null)?.use { c ->
                if (!c.moveToFirst()) return null
                val rel = c.getString(0)?.trimEnd('/') ?: return null
                val volume = c.getString(1) ?: return null
                val name = c.getString(2) ?: return null
                // MediaStore names the SD card by its UUID in lower case;
                // the storage provider uses the same UUID in upper case.
                val root = if (volume == android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY) {
                    "primary"
                } else {
                    volume.uppercase()
                }
                if (rel.isEmpty()) "$root:$name" else "$root:$rel/$name"
            }
        } catch (_: Exception) {
            null
        }
    }

    /** [uri]'s place in words: "Internal storage › Download" for a file
     *  on the phone, else the app that holds it ("Google Drive"). */
    private fun whereIs(uri: Uri): String {
        val id = storageDocId(uri)
        if (id != null) {
            val volume = id.substringBefore(':')
            val path = id.substringAfter(':', "")
            val root = if (volume == "primary") "Internal storage" else "SD card"
            val folder = path.substringBeforeLast('/', "")
            return if (folder.isEmpty()) root else "$root › " + folder.replace("/", " › ")
        }
        if (uri.scheme == "file") {
            val folder = uri.path?.substringBeforeLast('/', "") ?: ""
            return folder.removePrefix("/storage/emulated/0").trimStart('/').let {
                if (it.isEmpty()) "Internal storage" else "Internal storage › " + it.replace("/", " › ")
            }
        }
        if (uri.authority == "com.android.providers.downloads.documents") return "Downloads"
        return try {
            val info = packageManager.resolveContentProvider(uri.authority ?: "", 0)
            info?.loadLabel(packageManager)?.toString()?.takeIf { it.isNotBlank() }
                ?: "Another app"
        } catch (_: Exception) {
            "Another app"
        }
    }

    /** The folder holding [uri], as a document a file manager can open, or
     *  null when the provider has no folders to show. */
    private fun folderOf(uri: Uri): Uri? {
        // A download MediaStore could not place still lives under Download.
        val id = storageDocId(uri)
            ?: if (uri.authority == "com.android.providers.downloads.documents") "primary:Download/x"
            else return null
        val parent = id.substringBeforeLast('/', id.substringBefore(':') + ":")
        // Always the storage provider's folder, whichever provider gave the
        // file: that is the one a file manager can browse.
        return android.provider.DocumentsContract.buildDocumentUri(
            "com.android.externalstorage.documents",
            parent,
        )
    }

    /** Opens the folder holding [uri] in a file manager. Breeze itself
     *  accepts any type, so it would offer to open the folder too: it is
     *  left out, and the one file manager left is opened directly. No read
     *  grant is passed: the folder is the storage provider's, not ours to
     *  grant, and asking for it fails the whole start. */
    private fun showFolder(uri: Uri): Boolean {
        val folder = folderOf(uri) ?: return false
        val types = listOf(
            android.provider.DocumentsContract.Document.MIME_TYPE_DIR,
            "resource/folder",
        )
        for (type in types) {
            val view = Intent(Intent.ACTION_VIEW).setDataAndType(folder, type)
            val others = try {
                @Suppress("DEPRECATION")
                packageManager.queryIntentActivities(view, 0)
                    .map { it.activityInfo }
                    .filter { it.packageName != packageName }
            } catch (_: Exception) {
                emptyList()
            }
            if (others.isEmpty()) continue
            val start = if (others.size == 1) {
                Intent(view).setClassName(others[0].packageName, others[0].name)
            } else {
                Intent.createChooser(view, null).putExtra(
                    Intent.EXTRA_EXCLUDE_COMPONENTS,
                    arrayOf(android.content.ComponentName(this, MainActivity::class.java)),
                )
            }
            try {
                startActivity(start)
                return true
            } catch (_: Exception) {
            }
        }
        return false
    }

    private fun adoptLostPick(uri: Uri) {
        keepAccess(uri)
        io.execute {
            try {
                val (text, cs) = readDoc(uri)
                val name = displayName(uri)
                runOnUiThread {
                    pendingName = name
                    pendingText = text
                    pendingUri = uri.toString()
                    pendingCharset = cs
                    if (dartAsked) {
                        methodChannel?.invokeMethod("openFile", pendingMap())
                        clearPending()
                    }
                }
            } catch (e: Exception) {
                val why = if (e.message == "too large") "This file is too large to open (over 20 MB)"
                else "Couldn't open this file"
                runOnUiThread {
                    android.widget.Toast.makeText(this, why, android.widget.Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    /** A picked document's text and its encoding: UTF-16 by its BOM, else
     *  strict UTF-8, else Latin-1. The old lenient UTF-8 read turned every
     *  non-UTF-8 byte into U+FFFD, which the first save wrote over the
     *  user's real file. Refused past 20 MB, whether or not the provider
     *  reports a size. */
    private fun readDoc(uri: Uri): Pair<String, String> {
        val max = 20 * 1024 * 1024
        val bytes = contentResolver.openInputStream(uri).use { input ->
            if (input == null) throw IllegalStateException("no stream")
            val out = java.io.ByteArrayOutputStream()
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                out.write(buf, 0, n)
                if (out.size() > max) throw IllegalStateException("too large")
            }
            out.toByteArray()
        }
        // An odd byte count is not UTF-16, whatever its first bytes say.
        if (bytes.size >= 2 && bytes.size % 2 == 0 &&
            ((bytes[0] == 0xFF.toByte() && bytes[1] == 0xFE.toByte()) ||
                (bytes[0] == 0xFE.toByte() && bytes[1] == 0xFF.toByte()))
        ) {
            val le = bytes[0] == 0xFF.toByte()
            return Pair(String(bytes, Charsets.UTF_16), if (le) "UTF-16LE" else "UTF-16BE")
        }
        return try {
            val dec = Charsets.UTF_8.newDecoder()
                .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
            Pair(dec.decode(java.nio.ByteBuffer.wrap(bytes)).toString(), "UTF-8")
        } catch (_: java.nio.charset.CharacterCodingException) {
            // A Windows file (curly quotes, euro sign in 0x80-0x9F) reads as
            // Windows-1252 so those survive a save; bytes that code page
            // leaves undefined mean it is not one, so Latin-1, byte for byte.
            val undefined = setOf(0x81, 0x8D, 0x8F, 0x90, 0x9D)
            val cp1252 = bytes.any { (it.toInt() and 0xFF) in 0x80..0x9F } &&
                bytes.none { (it.toInt() and 0xFF) in undefined }
            if (cp1252) Pair(String(bytes, CP1252), "windows-1252")
            else Pair(String(bytes, Charsets.ISO_8859_1), "ISO-8859-1")
        }
    }

    /** [name], with the extension its content shows when it has none
     *  Breeze knows: some apps share a Word or RTF file under a bare number
     *  ("1000023"), and read by that name it would open, and save, as text. */
    private fun namedFor(name: String, text: String): String {
        val dot = name.lastIndexOf('.')
        val ext = if (dot > 0) name.substring(dot).lowercase() else ""
        if (ext == ".docx" || ext == ".rtf") return name
        val known = ext.length in 2..6 && ext.drop(1).all { it.isLetterOrDigit() }
        // A zip's first bytes are P K 3 4; an RTF file opens with {\rtf.
        val zip = text.length > 4 && text[0] == 'P' && text[1] == 'K' &&
            text[2].code == 3 && text[3].code == 4
        val head = text.trimStart()
        val rtf = head.startsWith("{") && head.drop(1).startsWith(92.toChar() + "rtf")
        return when {
            zip && text.contains("word/document.xml") ->
                if (known && ext != ".txt") name else "$name.docx"
            rtf -> if (known && ext != ".txt") name else "$name.rtf"
            else -> name
        }
    }

    private fun displayName(uri: Uri): String {
        if (uri.scheme == "content") {
            try {
                contentResolver.query(uri, null, null, null, null)?.use { c ->
                    val idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0 && c.moveToFirst()) {
                        val n = c.getString(idx)
                        if (!n.isNullOrBlank()) return n
                    }
                }
            } catch (_: Exception) {}
        }
        return uri.lastPathSegment?.substringAfterLast('/') ?: "Untitled.txt"
    }
}

/** Why an incoming file or text could not be opened, shown to the user. */
private class OpenFail(message: String) : Exception(message)
