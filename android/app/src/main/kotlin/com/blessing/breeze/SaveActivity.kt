package com.blessing.breeze

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.widget.Toast
import java.io.File

/**
 * "Save to Breeze" in other apps' share sheet and text-selection menu.
 *
 * Unlike sharing to "Breeze", which opens a new note with the text, this
 * saves the text straight into the Breeze folder and goes away: no app, no
 * screen, just a toast naming the file. The name is the first few words.
 *
 * It runs without Flutter, so it writes the folder directly. The app picks
 * the file up on its next refresh (it refreshes when it comes back).
 *
 * Exported, so everything the sender controls is distrusted: the file name
 * is cleaned to a bare name and the result must still be inside the folder,
 * and a file:// link is refused (it could point at Breeze's own private
 * files and copy them into a note).
 */
class SaveActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A recreation (rotation) must not save the same text twice.
        if (savedInstanceState != null) {
            finish()
            return
        }
        val intent = intent
        val app = applicationContext
        // Off the main thread: a shared file may come from a slow cloud
        // provider. The activity finishes at once; the toast follows.
        Thread {
            val msg = save(intent)
            Handler(Looper.getMainLooper()).post {
                Toast.makeText(app, msg, Toast.LENGTH_SHORT).show()
            }
        }.start()
        finish()
    }

    private fun save(intent: Intent?): String {
        return try {
            @Suppress("DEPRECATION")
            val shared = intent?.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            if (intent?.action == Intent.ACTION_SEND && shared != null &&
                isMedia(this, intent, shared)
            ) {
                return "Breeze saves text, not photos or media"
            }
            val (name, text) = read(intent) ?: return "Nothing to save"
            // Where Flutter's path_provider puts app documents
            // (getApplicationDocumentsDirectory -> app_flutter).
            val dir = File(applicationContext.getDir("flutter", MODE_PRIVATE), "Breeze")
            dir.mkdirs()
            // Checked BEFORE the name is claimed, so nothing is ever made
            // outside the folder.
            if (!File(dir, name.trimStart('.').ifBlank { "x" }).canonicalPath
                    .startsWith(dir.canonicalPath + File.separator)
            ) {
                return "Could not save to Breeze"
            }
            val file = freeName(dir, name)
            try {
                file.writeText(text, Charsets.UTF_8)
            } catch (e: Exception) {
                file.delete() // no empty file left behind
                throw e
            }
            "Saved to Breeze as ${file.name}"
        } catch (e: Exception) {
            "Could not save to Breeze"
        }
    }

    /** (file name, text), or null when there is nothing to save. */
    private fun read(intent: Intent?): Pair<String, String>? {
        if (intent == null) return null
        when (intent.action) {
            Intent.ACTION_PROCESS_TEXT -> {
                val t = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
                return if (t.isNullOrBlank()) null else Pair(nameFrom(t), t)
            }
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                val stream = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (stream != null) {
                    if (stream.scheme != "content") return null
                    // A */* share can still bring a photo here; not saved.
                    if (isMedia(this, intent, stream)) return null
                    val text = readUri(stream)
                    if (text.isBlank()) return null
                    val shown = displayName(stream)?.let { cleanName(it) }
                    return Pair(if (shown.isNullOrEmpty()) nameFrom(text) else shown, text)
                }
                val t = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                if (t.isNullOrBlank()) return null
                return Pair(nameFrom(t), t)
            }
        }
        return null
    }

    /** A sender's file name, reduced to a safe bare name: no folders, no
     *  reserved characters, no leading dots, at most 100 characters. */
    private fun cleanName(raw: String): String {
        val base = raw.substringAfterLast('/').substringAfterLast('\\')
            .replace(RESERVED, " ")
            .replace(Regex("\\s+"), " ")
            .trim()
            .trimStart('.')
            .trim()
        if (base.isEmpty()) return ""
        if (base.length <= 100) return base
        val dot = base.lastIndexOf('.')
        val ext = if (dot > 0 && base.length - dot <= 9) base.substring(dot) else ""
        return base.substring(0, 100 - ext.length).trim() + ext
    }

    /** "Buy milk and eggs tomorrow" -> "Buy milk and.txt": the first three
     *  words, at most 30 characters, made safe for a file name. */
    private fun nameFrom(text: String): String {
        val words = text.trim()
            .replace(RESERVED, " ")
            .split(Regex("\\s+"))
            .filter { it.isNotBlank() }
            .take(3)
            .joinToString(" ")
            .take(30)
            .trim()
            .trimStart('.')
        return (if (words.isEmpty()) "Saved note" else words) + ".txt"
    }

    /** A name no file has yet, CLAIMED by creating it, so two shares saved
     *  at the same moment can never pick the same name and overwrite. */
    private fun freeName(dir: File, name: String): File {
        val clean = name.trimStart('.').ifBlank { "Saved note.txt" }
        val dot = clean.lastIndexOf('.')
        val stem = if (dot > 0) clean.substring(0, dot) else clean
        val ext = if (dot > 0) clean.substring(dot) else ""
        var f = File(dir, clean)
        var i = 2
        while (!f.createNewFile()) {
            f = File(dir, "$stem $i$ext")
            i++
        }
        return f
    }

    /** Text of a shared file: UTF-16 by its BOM, else strict UTF-8, else
     *  Windows-1252 or Latin-1 (the same rules as opening a file). Refused past 20 MB. */
    private fun readUri(uri: Uri): String {
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
            return String(bytes, Charsets.UTF_16)
        }
        return try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
                .decode(java.nio.ByteBuffer.wrap(bytes)).toString()
        } catch (_: java.nio.charset.CharacterCodingException) {
            // A Windows file (curly quotes, euro sign in 0x80-0x9F) reads as
            // Windows-1252, as opening a file does; bytes that code page
            // leaves undefined mean it is not one, so Latin-1.
            val undefined = setOf(0x81, 0x8D, 0x8F, 0x90, 0x9D)
            val cp1252 = bytes.any { (it.toInt() and 0xFF) in 0x80..0x9F } &&
                bytes.none { (it.toInt() and 0xFF) in undefined }
            String(bytes, if (cp1252) java.nio.charset.Charset.forName("windows-1252") else Charsets.ISO_8859_1)
        }
    }

    private fun displayName(uri: Uri): String? = try {
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (idx >= 0 && c.moveToFirst()) c.getString(idx) else null
        }
    } catch (_: Exception) {
        null
    }

    private companion object {
        /** Characters no file name may hold: \ / : * ? " < > | and controls. */
        val RESERVED = Regex("[\\\\/:*?\"<>|\\p{Cntrl}]")
    }
}
