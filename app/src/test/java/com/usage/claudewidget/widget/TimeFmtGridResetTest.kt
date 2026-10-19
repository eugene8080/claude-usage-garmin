package com.usage.claudewidget.widget

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import java.util.Calendar
import java.util.TimeZone

/** The usage grid's reset column: 1445 / WED / NOV06 (Eugene, 2026-10-19). */
class TimeFmtGridResetTest {
    private val saved = TimeZone.getDefault()

    @Before fun utc() = TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
    @After fun restore() = TimeZone.setDefault(saved)

    private fun at(y: Int, mo: Int, d: Int, h: Int, mi: Int): Long = Calendar.getInstance().apply {
        clear(); set(y, mo - 1, d, h, mi)
    }.timeInMillis

    private val now = at(2026, 10, 19, 9, 0) // Monday 19 Oct 2026, 09:00

    @Test fun `within a day is a 24-hour time with no colon, always four digits`() {
        assertEquals(TimeFmt.GridReset("1445", isTime = true), TimeFmt.gridReset(at(2026, 10, 19, 14, 45), now))
        assertEquals(TimeFmt.GridReset("0905", isTime = true), TimeFmt.gridReset(at(2026, 10, 19, 9, 5), now))
    }

    @Test fun `within a week is the weekday in capitals`() {
        assertEquals(TimeFmt.GridReset("WED", isTime = false), TimeFmt.gridReset(at(2026, 10, 21, 10, 0), now))
    }

    @Test fun `beyond a week is month and two-digit day in capitals`() {
        assertEquals(TimeFmt.GridReset("NOV06", isTime = false), TimeFmt.gridReset(at(2026, 11, 6, 8, 0), now))
    }

    @Test fun `no reset and a past reset`() {
        assertEquals(TimeFmt.GridReset("-", isTime = false), TimeFmt.gridReset(0L, now))
        assertEquals(TimeFmt.GridReset("NOW", isTime = false), TimeFmt.gridReset(now - 1, now))
    }
}
