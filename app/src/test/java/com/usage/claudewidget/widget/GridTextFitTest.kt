package com.usage.claudewidget.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The usage grid's text must fit its room at Eugene's design sizes (2026-10-19) - on the phone
 * it did not: labels showed as "…" and two-digit numbers vanished (2026-10-20).
 *
 * On the JVM, Paint can't measure, so [GridTextFit.ems] uses Droid Sans Mono's fixed advance
 * (0.6 em) - the font the phone draws with.
 */
class GridTextFitTest {
    private fun fitted(text: String, size: Float, room: Float) =
        GridTextFit.fit(size, room, GridTextFit.ems(text))

    @Test fun `every label keeps its design size`() {
        for (label in listOf("5H", "1W", "FA", "PL", "AU", "AP")) {
            assertEquals(label, GridDesign.S_LABEL, fitted(label, GridDesign.S_LABEL, GridDesign.LABEL_ROOM), 0f)
        }
    }

    @Test fun `one and two digit numbers keep their design size`() {
        for (n in listOf("0", "5", "45", "99")) {
            assertEquals(n, GridDesign.S_NUM, fitted(n, GridDesign.S_NUM, GridDesign.NUM_ROOM), 0f)
        }
    }

    @Test fun `100 steps down until its advance fits the box plus half the halo`() {
        val size = fitted("100", GridDesign.S_NUM, GridDesign.NUM_ROOM)
        assertTrue("size $size", size < GridDesign.S_NUM)
        assertEquals(GridDesign.NUM_ROOM, size * GridTextFit.ems("100"), 1e-4f)
    }

    @Test fun `every reset form keeps its design size`() {
        assertEquals(GridDesign.S_RESET_TIME, fitted("1445", GridDesign.S_RESET_TIME, GridDesign.RESET_ROOM), 0f)
        for (r in listOf("WED", "NOV06", "NOW", "-")) {
            assertEquals(r, GridDesign.S_RESET, fitted(r, GridDesign.S_RESET, GridDesign.RESET_ROOM), 0f)
        }
    }

    @Test fun `empty text keeps the desired size`() {
        assertEquals(0f, GridTextFit.ems(""), 0f)
        assertEquals(GridDesign.S_RESET, fitted("", GridDesign.S_RESET, GridDesign.RESET_ROOM), 0f)
    }
}
