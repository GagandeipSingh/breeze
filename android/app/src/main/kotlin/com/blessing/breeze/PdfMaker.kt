package com.blessing.breeze

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.text.Layout
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.ForegroundColorSpan
import android.text.style.MetricAffectingSpan
import android.text.style.StrikethroughSpan
import android.text.style.UnderlineSpan
import io.flutter.FlutterInjector
import java.io.File
import java.io.FileOutputStream

/**
 * A note as a PDF, laid out by Android itself, the same way the phone draws
 * text on screen: every script the phone can show (Hindi, Arabic, Chinese,
 * Tamil...), colour emoji and right-to-left lines come out right, as real
 * selectable text, with the phone's own fonts filling in whatever Inter
 * lacks. Drawing such lines as pictures in Dart took tens of seconds for a
 * long note; this takes well under one.
 *
 * Paragraphs arrive already split and styled by Dart (the same Markdown and
 * code colours as the editor), so both sides agree on what a note says.
 */
class PdfMaker(private val context: Context) {
    // Md flags, as in lib/logic/markdown_lite.dart.
    private val bold = 1
    private val italic = 2
    private val strike = 4
    private val link = 8
    private val h1 = 64
    private val h2 = 128
    private val h3 = 256
    private val heading = h1 or h2 or h3
    private val underline = 512

    // A4 in points, with the same 2 cm margins as the Dart PDF.
    private val pageW = 595
    private val pageH = 842
    private val margin = 56.7f
    private val footerSpace = 22f
    private val contentW get() = pageW - 2 * margin
    private val bodySize = 11f
    private val codeSize = 9.5f

    private fun font(name: String): Typeface? = try {
        val key = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset("assets/fonts/pdf/$name")
        Typeface.createFromAsset(context.assets, key)
    } catch (_: Exception) {
        null
    }

    private val regular by lazy { font("Inter-Regular.ttf") ?: Typeface.DEFAULT }
    private val boldFace by lazy { font("Inter-Bold.ttf") ?: Typeface.DEFAULT_BOLD }
    private val italicFace by lazy { font("Inter-Italic.ttf") ?: Typeface.create(Typeface.DEFAULT, Typeface.ITALIC) }
    private val boldItalicFace by lazy {
        font("Inter-BoldItalic.ttf") ?: Typeface.create(Typeface.DEFAULT, Typeface.BOLD_ITALIC)
    }
    private val mono = Typeface.MONOSPACE
    private val monoBold = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
    private val monoItalic = Typeface.create(Typeface.MONOSPACE, Typeface.ITALIC)
    private val monoBoldItalic = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD_ITALIC)

    /** Face and exact size (points; AbsoluteSizeSpan only takes whole
     *  numbers, which printed 9.5 pt code at 9). */
    private class FaceSpan(val face: Typeface, val size: Float) : MetricAffectingSpan() {
        override fun updateMeasureState(p: TextPaint) {
            p.typeface = face
            p.textSize = size
            p.fontFeatureSettings = PLAIN_GLYPHS
        }

        override fun updateDrawState(p: TextPaint) {
            p.typeface = face
            p.textSize = size
            p.fontFeatureSettings = PLAIN_GLYPHS
        }
    }

    private fun sizeFor(f: Int, code: Boolean): Float = when {
        f and h1 != 0 -> 18f
        f and h2 != 0 -> 15f
        f and h3 != 0 -> 13f
        code -> codeSize
        else -> bodySize
    }

    private fun faceFor(f: Int, code: Boolean): Typeface {
        val b = f and (bold or heading) != 0
        val i = f and italic != 0
        if (code) {
            return when {
                b && i -> monoBoldItalic
                b -> monoBold
                i -> monoItalic // comments, as in the editor
                else -> mono
            }
        }
        return when {
            b && i -> boldItalicFace
            b -> boldFace
            i -> italicFace
            else -> regular
        }
    }

    /** One paragraph: its laid-out text and the gaps around it. */
    private class Block(
        val layout: StaticLayout,
        val top: Float,
        val bottom: Float,
        val rule: Boolean,
        val lines: List<Under> = emptyList(),
    )

    /** Text [start, end) underlined in [colour], at [size] points. */
    private class Under(val start: Int, val end: Int, val size: Float, val colour: Int)

    /** A slice of a block on one page: lines [from, to) drawn at [y]. */
    private class Piece(val block: Block, val from: Int, val to: Int, val y: Float)

    /**
     * [paras]: per paragraph, its line flags then (text, flags, colour)
     * triples. The first paragraph is the title. Writes the PDF to [out].
     */
    /** [b]'s text in white, a little fatter, without its colours (a colour
     *  filter on the paint is ignored when drawing into a PDF): same fonts
     *  and sizes, so the same line breaks. Drawn over the underlines before
     *  the text, so a letter that hangs down (g, y, ू) breaks the line
     *  around it. Made when drawn, not kept, so a big note does not hold
     *  two layouts of every underlined paragraph. */
    private fun haloOf(b: Block): StaticLayout? {
        val l = b.layout
        val hs = SpannableStringBuilder(l.text)
        for (s in hs.getSpans(0, hs.length, ForegroundColorSpan::class.java)) hs.removeSpan(s)
        for (s in hs.getSpans(0, hs.length, android.text.style.BackgroundColorSpan::class.java)) hs.removeSpan(s)
        val hp = TextPaint(l.paint).apply {
            color = 0xFFFFFFFF.toInt()
            style = Paint.Style.FILL_AND_STROKE
            strokeWidth = b.lines.maxOf { it.size } * 0.16f
        }
        return StaticLayout.Builder.obtain(hs, 0, hs.length, hp, l.width)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setTextDirection(TextDirectionHeuristics.FIRSTSTRONG_LTR)
            .setLineSpacing(l.spacingAdd, 1f)
            .setIncludePad(true)
            .build()
            .takeIf { it.lineCount == l.lineCount }
    }

    /** One line of a paragraph, laid out alone, and its white halo. */
    private class One(val text: StaticLayout, val halo: StaticLayout?)

    /** [piece]'s lines each laid out on its own, breaking exactly where the
     *  paragraph broke, in the paragraph's direction; drawn at the
     *  paragraph line's baseline they land on the same pixels. Null when
     *  any line would not stay one line: the piece is then drawn whole. */
    private fun linesOf(piece: Piece, halo: StaticLayout?): List<One>? {
        val l = piece.block.layout
        val out = ArrayList<One>(piece.to - piece.from)
        for (line in piece.from until piece.to) {
            val s = l.getLineStart(line)
            val e = l.getLineEnd(line)
            val rtl = l.getParagraphDirection(line) == Layout.DIR_RIGHT_TO_LEFT
            val text = single(l, s, e, rtl) ?: return null
            val h = if (halo == null) null else (single(halo, s, e, rtl) ?: return null)
            out.add(One(text, h))
        }
        return out
    }

    private fun single(l: StaticLayout, s: Int, e: Int, rtl: Boolean): StaticLayout? {
        if (e <= s) return null
        val one = StaticLayout.Builder.obtain(l.text, s, e, l.paint, l.width)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setTextDirection(if (rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR)
            .setLineSpacing(l.spacingAdd, 1f)
            .setIncludePad(true)
            .build()
        return one.takeIf { it.lineCount == 1 }
    }

    /** What [line] of [l] says, without the break or spaces it wraps at. */
    private fun lineText(l: Layout, line: Int): String =
        l.text.subSequence(l.getLineStart(line), l.getLineEnd(line)).toString().trimEnd()

    private val underPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val underPath = android.graphics.Path()
    private val underBounds = android.graphics.RectF()

    /** The underlines of [piece]'s lines: one straight line per text line,
     *  at the same depth under its baseline whatever fonts (emoji, Hindi)
     *  the words are drawn in. */
    private fun drawUnders(c: Canvas, piece: Piece) {
        val l = piece.block.layout
        for (u in piece.block.lines) {
            for (line in piece.from until piece.to) {
                var s = maxOf(u.start, l.getLineStart(line))
                var e = minOf(u.end, l.getLineEnd(line))
                // Not under the line break or the spaces a line wraps at.
                while (e > s && l.text[e - 1].isWhitespace()) e--
                while (s < e && l.text[s] == '\n') s++
                if (s >= e) continue
                underPath.reset()
                l.getSelectionPath(s, e, underPath)
                underPath.computeBounds(underBounds, true)
                if (underBounds.width() <= 0f) continue
                val y = l.getLineBaseline(line) + u.size * 0.2f
                underPaint.color = u.colour
                underPaint.strokeWidth = maxOf(0.5f, u.size / 16f)
                c.drawLine(underBounds.left, y, underBounds.right, y, underPaint)
            }
        }
    }

    fun make(paras: List<List<Any?>>, code: Boolean, out: File) {
        val width = contentW.toInt()
        val blocks = ArrayList<Block>(paras.size)
        for ((index, p) in paras.withIndex()) {
            val lineFlags = (p[0] as Number).toInt()
            val sb = SpannableStringBuilder()
            val unders = ArrayList<Under>()
            var k = 1
            while (k + 2 < p.size) {
                val text = p[k] as String
                val f = (p[k + 1] as Number).toInt() or lineFlags
                val colour = (p[k + 2] as Number).toLong().toInt()
                k += 3
                if (text.isEmpty()) continue
                val start = sb.length
                sb.append(text)
                val end = sb.length
                val title = index == 0
                sb.setSpan(
                    FaceSpan(if (title) boldFace else faceFor(f, code), sizeFor(f, code && !title)),
                    start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
                )
                if (f and strike != 0) sb.setSpan(StrikethroughSpan(), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                val ink = when {
                    colour != 0 -> colour
                    f and link != 0 -> 0xFF1A5FD0.toInt()
                    else -> 0
                }
                // Drawn by hand after the text (see drawUnders): Android's
                // own underline sits where each font says, so under an emoji
                // it dropped lower and thicker than under the words beside it.
                if (f and (link or underline) != 0) {
                    unders.add(Under(start, end, sizeFor(f, code && !title), if (ink != 0) ink else 0xFF000000.toInt()))
                }
                if (ink != 0) sb.setSpan(ForegroundColorSpan(ink), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            if (sb.isEmpty()) sb.append(" ")
            val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
                color = 0xFF000000.toInt()
                textSize = sizeFor(lineFlags, code && index != 0)
                typeface = if (code && index != 0) mono else regular
                fontFeatureSettings = PLAIN_GLYPHS
            }
            val extra = if (code && index != 0) 1.5f else 3f
            val layout = StaticLayout.Builder.obtain(sb, 0, sb.length, paint, width)
                .setAlignment(Layout.Alignment.ALIGN_NORMAL)
                // An Arabic or Hebrew line reads right to left and sits on
                // the right, as on screen.
                .setTextDirection(TextDirectionHeuristics.FIRSTSTRONG_LTR)
                .setLineSpacing(extra, 1f)
                .setIncludePad(true)
                .build()
            val isHeading = lineFlags and heading != 0
            blocks.add(
                when {
                    index == 0 -> Block(layout, 0f, 14f, true, unders)
                    isHeading -> Block(layout, 6f, 7f, false, unders)
                    code -> Block(layout, 0f, 1.5f, false, unders)
                    else -> Block(layout, 0f, 5f, false, unders)
                },
            )
        }

        // First pass: where every line goes. A paragraph longer than the
        // room left is split between lines, never through one.
        val bottomLimit = pageH - margin - footerSpace
        val pages = ArrayList<ArrayList<Piece>>()
        var page = ArrayList<Piece>()
        pages.add(page)
        var y = margin
        for (b in blocks) {
            if (page.isNotEmpty()) y += b.top
            val l = b.layout
            var from = 0
            while (from < l.lineCount) {
                val startTop = l.getLineTop(from).toFloat()
                var to = from
                while (to < l.lineCount && y + (l.getLineBottom(to) - startTop) <= bottomLimit) to++
                if (to == from) {
                    if (page.isEmpty()) {
                        to = from + 1 // one line taller than a page: it goes alone
                    } else {
                        page = ArrayList()
                        pages.add(page)
                        y = margin
                        continue
                    }
                }
                page.add(Piece(b, from, to, y))
                y += l.getLineBottom(to - 1) - startTop
                from = to
                if (from < l.lineCount) {
                    page = ArrayList()
                    pages.add(page)
                    y = margin
                }
            }
            y += b.bottom
        }

        val doc = PdfDocument()
        try {
            val footer = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
                color = 0xFF757575.toInt()
                textSize = 9f
                typeface = regular
                textAlign = Paint.Align.RIGHT
                fontFeatureSettings = PLAIN_GLYPHS
            }
            val rule = Paint().apply {
                color = 0xFF9E9E9E.toInt()
                strokeWidth = 0.6f
            }
            val labels = List(pages.size) { ArrayList<PdfText.Label>() }
            for ((i, pieces) in pages.withIndex()) {
                val p = doc.startPage(PdfDocument.PageInfo.Builder(pageW, pageH, i + 1).create())
                val c: Canvas = p.canvas
                for (piece in pieces) {
                    val l = piece.block.layout
                    val top = l.getLineTop(piece.from).toFloat()
                    val bottom = l.getLineBottom(piece.to - 1).toFloat()
                    c.save()
                    c.translate(margin, piece.y - top)
                    c.clipRect(0f, top, contentW, bottom)
                    val halo = if (piece.block.lines.isEmpty()) null else haloOf(piece.block)
                    // Line first, then the letters in white a little fatter,
                    // then the letters: where a letter hangs down (g, y, ू)
                    // the line breaks around it.
                    if (piece.block.lines.isNotEmpty()) drawUnders(c, piece)
                    val ones = linesOf(piece, halo)
                    if (ones == null) {
                        halo?.draw(c)
                        l.draw(c)
                    } else {
                        // One line at a time, each under its own offset, so
                        // the PDF holds every line's letters together and
                        // PdfText can tell a reader what that line says.
                        for ((k, one) in ones.withIndex()) {
                            val line = piece.from + k
                            val dy = (l.getLineBaseline(line) - one.text.getLineBaseline(0)).toFloat()
                            c.save()
                            c.translate(0f, dy)
                            one.halo?.draw(c)
                            one.text.draw(c)
                            c.restore()
                            val said = lineText(l, line)
                            if (PdfText.needsLabel(said)) {
                                labels[i].add(PdfText.Label(margin, piece.y - top + dy, said))
                            }
                        }
                    }
                    c.restore()
                    if (piece.block.rule && piece.to == l.lineCount) {
                        val ly = piece.y + (bottom - top) + 5f
                        c.drawLine(margin, ly, pageW - margin, ly, rule)
                    }
                }
                if (pages.size > 1) {
                    c.drawText("${i + 1} / ${pages.size}", pageW - margin, pageH - margin + 4f, footer)
                }
                doc.finishPage(p)
            }
            out.parentFile?.mkdirs()
            FileOutputStream(out).use { doc.writeTo(it) }
            // What each Hindi, Arabic or emoji line says, for copy and
            // search. A failure leaves the PDF as Android wrote it.
            try {
                PdfText.label(out, labels)
            } catch (_: Throwable) {
            }
        } finally {
            doc.close()
        }
    }
}

/** Inter swaps in look-alike glyphs by context (the raised colon in
 *  "10:00"), and Android's PDF writer cannot say which letter such a glyph
 *  is: "10:00" then copies and searches as "10", a stray mark, "00".
 *  Off, every glyph is
 *  the letter's own. */
private const val PLAIN_GLYPHS = "'calt' 0"
