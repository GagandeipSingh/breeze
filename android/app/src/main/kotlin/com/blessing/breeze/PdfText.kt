package com.blessing.breeze

import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.Deflater
import java.util.zip.Inflater

/**
 * Tells PDF readers what a line SAYS, so it copies and searches right.
 *
 * Android's PDF writer stores the shapes it drew, not the letters they came
 * from. For English that is the same thing; for Hindi, Arabic, Tamil and
 * emoji it is not: a conjunct is one shape for three letters, a vowel sign
 * is drawn before the letter it follows, a family emoji is one picture for
 * five code points. A reader then guesses the letters back from the shapes
 * and copies "नम￾ते" for "नमस्ते".
 *
 * PDF's answer is ActualText: a marked span saying "these shapes read as
 * this text". Every reader that copies text honours it (pdfium, so Chrome
 * and most Android viewers; MuPDF; Acrobat). Nothing is redrawn, so the page
 * looks exactly as Android drew it.
 *
 * PdfMaker draws each such line under its own offset; Android's writer puts
 * a matrix change ("1 0 0 1 x y cm") right after a "q" whenever the offset
 * changes, so a line's letters sit together inside one q ... Q group that
 * starts with its own x and y. The span goes around that group's contents.
 * The new page contents are appended as an incremental update, so the
 * bytes Android wrote are kept as they are.
 */
object PdfText {
    /** A line drawn at page offset ([x], [y]) that reads [text]. */
    class Label(val x: Float, val y: Float, val text: String)

    /** Whether a reader would get [s] wrong from its shapes alone: scripts
     *  that join, reorder or stack letters, marks, and emoji. Plain Latin,
     *  Greek, Cyrillic and Chinese copy right already and keep the reader's
     *  letter-by-letter selection. */
    fun needsLabel(s: String): Boolean {
        // A right-to-left line copies right already, and a label made it
        // worse: pdfium reversed its words. So Arabic and Hebrew lines keep
        // the reader's own reading.
        var j = 0
        while (j < s.length) {
            val c = s.codePointAt(j)
            if (c in 0x0590..0x08FF || c in 0xFB1D..0xFDFF || c in 0xFE70..0xFEFF ||
                c in 0x10800..0x10FFF || c in 0x1E800..0x1EFFF
            ) return false
            j += Character.charCount(c)
        }
        var i = 0
        while (i < s.length) {
            val c = s.codePointAt(i)
            if (c in 0x0300..0x036F || // combining marks
                c in 0x0900..0x1CFF || // Indic, South-East Asian...
                c in 0x1DC0..0x1DFF ||
                c in 0x200C..0x200F || // joiners, direction marks
                c in 0x202A..0x202E ||
                c in 0x2066..0x2069 ||
                c in 0x2600..0x27BF || // symbols that draw as emoji
                c in 0x2B00..0x2BFF ||
                c in 0xA800..0xABFF || // more Indic and South-East Asian
                c in 0xFE00..0xFE0F || // variation selectors
                c in 0xFE20..0xFE2F ||
                c >= 0x10000 // emoji and historic scripts
            ) return true
            i += Character.charCount(c)
        }
        return false
    }

    /** Adds [labels] (per page, in page order) to the PDF [file]. Throws on
     *  anything unexpected; the caller then keeps the file as it was. */
    fun label(file: File, labels: List<List<Label>>) {
        if (labels.all { it.isEmpty() }) return
        val bytes = file.readBytes()
        val pdf = Pdf(bytes)
        val pages = pdf.pages()
        if (pages.size != labels.size) return
        val out = ByteArrayOutputStream()
        out.write(bytes)
        if (bytes.last() != '\n'.code.toByte()) out.write('\n'.code)
        val offsets = ArrayList<Pair<Int, Int>>()
        for ((page, pageLabels) in pages.zip(labels)) {
            if (pageLabels.isEmpty()) continue
            val num = pdf.contentsOf(page) ?: continue
            val old = pdf.streamOf(num) ?: continue
            val new = mark(String(old, Charsets.ISO_8859_1), pageLabels) ?: continue
            val data = deflate(new.toByteArray(Charsets.ISO_8859_1))
            offsets.add(num to out.size())
            out.write("$num 0 obj\n<</Filter /FlateDecode /Length ${data.size}>> stream\n".latin1())
            out.write(data)
            out.write("\nendstream\nendobj\n".latin1())
        }
        if (offsets.isEmpty()) return
        val xref = out.size()
        val sb = StringBuilder("xref\n")
        for ((num, at) in offsets.sortedBy { it.first }) {
            sb.append("$num 1\n").append(String.format("%010d 00000 n \n", at))
        }
        sb.append("trailer\n<<").append(pdf.trailerKeep()).append(" /Prev ${pdf.startXref}>>\n")
        sb.append("startxref\n$xref\n%%EOF\n")
        out.write(sb.toString().latin1())
        val tmp = File(file.path + ".tmp")
        tmp.writeBytes(out.toByteArray())
        if (!tmp.renameTo(file)) {
            file.writeBytes(tmp.readBytes())
            tmp.delete()
        }
    }

    /** [content] with each labelled line's group wrapped in an ActualText
     *  span; null when no line was found. */
    internal fun mark(content: String, labels: List<Label>): String? {
        val toks = tokens(content)
        val used = BooleanArray(labels.size)
        val inserts = ArrayList<Pair<Int, String>>() // position, text
        var k = 0
        while (k < toks.size) {
            val t = toks[k]
            // "q" then "1 0 0 1 x y cm": a group drawn at offset (x, y).
            if (t.op == "q" && k + 7 < toks.size && toks[k + 7].op == "cm" &&
                (1..6).all { toks[k + it].op == null }
            ) {
                val m = (1..6).map { toks[k + it].text.toFloatOrNull() }
                if (m.all { it != null } && m[0] == 1f && m[1] == 0f && m[2] == 0f && m[3] == 1f) {
                    val x = m[4]!!
                    val y = m[5]!!
                    val end = closing(toks, k)
                    val hit = labels.indices.firstOrNull {
                        !used[it] && kotlin.math.abs(labels[it].x - x) < 0.02f &&
                            kotlin.math.abs(labels[it].y - y) < 0.02f
                    }
                    if (end > 0 && hit != null && (k + 8 until end).any { toks[it].op == "BT" }) {
                        used[hit] = true
                        inserts.add(toks[k + 7].end to "\n/Span <</ActualText <${hex(labels[hit].text)}>>> BDC")
                        inserts.add(toks[end].start to "EMC\n")
                    }
                }
            }
            k++
        }
        if (inserts.isEmpty()) return null
        val sb = StringBuilder(content.length + inserts.sumOf { it.second.length })
        var at = 0
        for ((pos, text) in inserts.sortedBy { it.first }) {
            sb.append(content, at, pos).append(text)
            at = pos
        }
        sb.append(content, at, content.length)
        return sb.toString()
    }

    /** The index of the "Q" closing the "q" at [open], or -1. */
    private fun closing(toks: List<Tok>, open: Int): Int {
        var depth = 0
        for (k in open until toks.size) {
            when (toks[k].op) {
                "q" -> depth++
                "Q" -> if (--depth == 0) return k
            }
        }
        return -1
    }

    private fun hex(s: String): String {
        val sb = StringBuilder("FEFF")
        for (ch in s) sb.append(String.format("%04X", ch.code))
        return sb.toString()
    }

    /** A content-stream token: [op] is the operator name, or null for an
     *  operand (number, name, string, array, dictionary). */
    private class Tok(val start: Int, val end: Int, val text: String, val op: String?)

    private fun tokens(s: String): List<Tok> {
        val out = ArrayList<Tok>()
        var i = 0
        val n = s.length
        fun delim(c: Char) = c.isWhitespace() || c in "()<>[]{}/%"
        while (i < n) {
            val c = s[i]
            when {
                c.isWhitespace() -> i++
                c == '%' -> while (i < n && s[i] != '\n' && s[i] != '\r') i++
                c == '(' -> { // literal string, nested and escaped
                    val st = i
                    var depth = 0
                    while (i < n) {
                        val ch = s[i]
                        if (ch == '\\') i++ else if (ch == '(') depth++ else if (ch == ')' && --depth == 0) { i++; break }
                        i++
                    }
                    out.add(Tok(st, i, s.substring(st, i), null))
                }
                c == '<' && i + 1 < n && s[i + 1] == '<' -> { i += 2; out.add(Tok(i - 2, i, "<<", null)) }
                c == '>' && i + 1 < n && s[i + 1] == '>' -> { i += 2; out.add(Tok(i - 2, i, ">>", null)) }
                c == '<' -> {
                    val st = i
                    while (i < n && s[i] != '>') i++
                    i++
                    out.add(Tok(st, i, s.substring(st, minOf(i, n)), null))
                }
                c == '[' || c == ']' || c == '{' || c == '}' -> { out.add(Tok(i, i + 1, c.toString(), null)); i++ }
                else -> {
                    val st = i
                    if (c == '/') i++
                    while (i < n && !delim(s[i])) i++
                    if (i == st) i++
                    val w = s.substring(st, i)
                    val operand = w.startsWith("/") || w.toDoubleOrNull() != null ||
                        w == "true" || w == "false" || w == "null"
                    out.add(Tok(st, i, w, if (operand) null else w))
                }
            }
        }
        return out
    }

    private fun deflate(b: ByteArray): ByteArray {
        val d = Deflater(Deflater.BEST_COMPRESSION)
        d.setInput(b)
        d.finish()
        val out = ByteArrayOutputStream(b.size / 3 + 64)
        val buf = ByteArray(16384)
        while (!d.finished()) out.write(buf, 0, d.deflate(buf))
        d.end()
        return out.toByteArray()
    }

    private fun String.latin1() = toByteArray(Charsets.ISO_8859_1)

    /** Just enough of a PDF reader for what Android's writer produces: a
     *  classic xref table, a page tree, Flate content streams. */
    private class Pdf(val bytes: ByteArray) {
        val text = String(bytes, Charsets.ISO_8859_1)
        val startXref: Int
        private val offsets = HashMap<Int, Int>()
        private val trailer: String

        init {
            val sx = text.lastIndexOf("startxref")
            require(sx >= 0)
            startXref = Regex("""\d+""").find(text, sx + 9)!!.value.toInt()
            require(text.startsWith("xref", startXref))
            var at = text.indexOf('\n', startXref) + 1
            while (true) {
                val head = Regex("""^\s*(\d+)\s+(\d+)\s*$""", RegexOption.MULTILINE)
                val lineEnd = text.indexOf('\n', at)
                val line = text.substring(at, lineEnd).trim()
                if (line.startsWith("trailer")) break
                val m = head.find(line) ?: error("xref")
                val first = m.groupValues[1].toInt()
                val count = m.groupValues[2].toInt()
                at = lineEnd + 1
                for (j in 0 until count) {
                    val e = text.indexOf('\n', at)
                    val parts = text.substring(at, e).trim().split(Regex("""\s+"""))
                    if (parts.size >= 3 && parts[2] == "n") offsets[first + j] = parts[0].toInt()
                    at = e + 1
                }
            }
            val ts = text.indexOf("<<", at)
            trailer = text.substring(ts, matchDict(ts))
        }

        /** The trailer's /Root, /Info and /ID, for the update's trailer. */
        fun trailerKeep(): String {
            val sb = StringBuilder()
            sb.append(" /Size ").append(Regex("""/Size\s+(\d+)""").find(trailer)!!.groupValues[1])
            for (key in listOf("Root", "Info")) {
                Regex("""/$key\s+(\d+\s+\d+\s+R)""").find(trailer)?.let { sb.append(" /$key ").append(it.groupValues[1]) }
            }
            Regex("""/ID\s*(\[[^\]]*\])""").find(trailer)?.let { sb.append(" /ID ").append(it.groupValues[1]) }
            return sb.toString()
        }

        private fun matchDict(open: Int): Int {
            var depth = 0
            var i = open
            while (i < text.length - 1) {
                if (text[i] == '<' && text[i + 1] == '<') { depth++; i += 2; continue }
                if (text[i] == '>' && text[i + 1] == '>') { depth--; i += 2; if (depth == 0) return i; continue }
                i++
            }
            error("dict")
        }

        /** Object [num]'s dictionary text, and where its body ends. */
        private fun dict(num: Int): Pair<String, Int>? {
            val at = offsets[num] ?: return null
            val ob = text.indexOf("obj", at)
            val ds = text.indexOf("<<", ob)
            if (ds < 0 || ds - ob > 20) return null
            val de = matchDict(ds)
            return text.substring(ds, de) to de
        }

        private fun ref(d: String, key: String): Int? =
            Regex("""/$key\s+(\d+)\s+\d+\s+R""").find(d)?.groupValues?.get(1)?.toInt()

        /** The page objects, in reading order. */
        fun pages(): List<Int> {
            val root = Regex("""/Root\s+(\d+)\s+\d+\s+R""").find(trailer)!!.groupValues[1].toInt()
            val out = ArrayList<Int>()
            fun walk(num: Int, depth: Int) {
                require(depth < 32)
                val d = dict(num)?.first ?: error("page tree")
                val kids = Regex("""/Kids\s*\[([^\]]*)\]""").find(d)
                if (kids != null) {
                    for (m in Regex("""(\d+)\s+\d+\s+R""").findAll(kids.groupValues[1])) walk(m.groupValues[1].toInt(), depth + 1)
                } else {
                    out.add(num)
                }
            }
            walk(ref(dict(root)!!.first, "Pages")!!, 0)
            return out
        }

        /** The page's single content stream object, or null. */
        fun contentsOf(page: Int): Int? {
            val d = dict(page)?.first ?: return null
            return ref(d, "Contents")
        }

        /** Object [num]'s stream, inflated when Flate. */
        fun streamOf(num: Int): ByteArray? {
            val (d, de) = dict(num) ?: return null
            var s = text.indexOf("stream", de)
            if (s < 0) return null
            s += 6
            if (text[s] == '\r') s++
            if (text[s] == '\n') s++
            val lenDirect = Regex("""/Length\s+(\d+)(?!\s+\d+\s+R)""").find(d)?.groupValues?.get(1)?.toInt()
            val len = lenDirect ?: run {
                val lr = ref(d, "Length") ?: return null
                val at = offsets[lr] ?: return null
                Regex("""obj\s*(\d+)""").find(text, at)!!.groupValues[1].toInt()
            }
            val raw = bytes.copyOfRange(s, s + len)
            if (!d.contains("/FlateDecode")) return if (d.contains("/Filter")) null else raw
            val inf = Inflater()
            inf.setInput(raw)
            val out = ByteArrayOutputStream(len * 4)
            val buf = ByteArray(16384)
            while (!inf.finished()) {
                val n = inf.inflate(buf)
                if (n == 0 && (inf.needsInput() || inf.needsDictionary())) break
                out.write(buf, 0, n)
            }
            inf.end()
            return out.toByteArray()
        }
    }
}
