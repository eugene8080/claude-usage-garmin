package com.usage.claudewidget.widget

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object TimeFmt {
    /**
     * When a window resets, as an absolute wall-clock time - the way the Claude usage menu
     * (and the watch glance) states it, rather than a countdown.
     *
     * Absolute rather than relative is the correct choice for a widget specifically: it only
     * re-renders on the ~15-minute refresh, so a countdown like "2h" would sit visibly wrong
     * for most of the interval between refreshes, while "5:00 PM" stays true no matter when
     * it is read. The format follows the distance, which maps onto the windows: a clock time
     * within a day (the 5-hour session), a weekday within the week, a month/day beyond that
     * (the weekly caps).
     *
     * @param is24h the device's clock setting, from DateFormat.is24HourFormat(context).
     */
    fun resetsAt(
        resetEpochMs: Long,
        now: Long = System.currentTimeMillis(),
        is24h: Boolean = false,
    ): String {
        if (resetEpochMs <= 0L) return "-"
        val diff = resetEpochMs - now
        if (diff <= 0L) return "now"
        val pattern = when {
            diff < DAY_MS -> if (is24h) "H:mm" else "h:mm a"
            diff < 7 * DAY_MS -> "EEE"      // "Tue"
            else -> "MMM d"                 // "Sep 22"
        }
        return SimpleDateFormat(pattern, Locale.getDefault()).format(Date(resetEpochMs))
    }

    private const val DAY_MS = 86_400_000L

    /** A reset as the usage grid writes it, and whether it is a time (it has its own size). */
    data class GridReset(val text: String, val isTime: Boolean)

    /**
     * The usage grid's reset column (Eugene, 2026-10-19): the same distance rule as [resetsAt],
     * in the grid's own compact style - a time within a day as 24-hour digits with no colon
     * (`1445`, `0905`, whatever the phone's 12/24-hour setting), a weekday in capitals (`WED`),
     * a date as month + two-digit day in capitals (`NOV06`). English names, so the style holds
     * whatever the phone's language.
     */
    fun gridReset(resetEpochMs: Long, now: Long = System.currentTimeMillis()): GridReset {
        if (resetEpochMs <= 0L) return GridReset("-", isTime = false)
        val diff = resetEpochMs - now
        if (diff <= 0L) return GridReset("NOW", isTime = false)
        val (pattern, isTime) = when {
            diff < DAY_MS -> "HHmm" to true
            diff < 7 * DAY_MS -> "EEE" to false
            else -> "MMMdd" to false
        }
        val text = SimpleDateFormat(pattern, Locale.ENGLISH).format(Date(resetEpochMs)).uppercase(Locale.ENGLISH)
        return GridReset(text, isTime)
    }

    /** Snapshot is considered stale once older than ~2 refresh cycles. */
    fun isStale(fetchedAt: Long, now: Long = System.currentTimeMillis()): Boolean {
        if (fetchedAt <= 0L) return true
        return now - fetchedAt > 31 * 60 * 1000L // > 31 min
    }
}
