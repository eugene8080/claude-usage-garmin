package com.usage.claudewidget.watch

import com.usage.claudewidget.data.CodexWatch
import com.usage.claudewidget.data.CursorWatch
import com.usage.claudewidget.data.ModelWindow
import com.usage.claudewidget.data.UsageSnapshot
import com.usage.claudewidget.data.WatchSnapshot
import com.usage.claudewidget.data.Window
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The values inside each key group. Which keys exist and how they group is checked against
 * the watch side by garmin/tools/check_contract.py; this checks what the phone puts in them.
 */
class WatchBridgePayloadTest {

    private val claude = UsageSnapshot(
        fiveHour = Window(12.4f, 1_792_310_400_000L),
        sevenDay = Window(40.6f, 1_792_656_000_000L),
        modelWeekly = ModelWindow("Fable", Window(3f, 1_792_656_000_000L)),
        fetchedAtEpochMs = 1_792_300_000_999L,
    )

    @Test fun `claude goes as whole percents and epoch seconds, with the model group`() {
        val payload = WatchBridge.payloadOf(WatchSnapshot(claude, null, null))
        assertEquals(
            mapOf(
                "fh" to 12, "fhr" to 1_792_310_400, "wk" to 40, "wkr" to 1_792_656_000,
                "ts" to 1_792_300_000, "mw" to 3, "mwr" to 1_792_656_000, "mwn" to "Fable",
            ),
            payload,
        )
    }

    @Test fun `no model cap leaves the model group out`() {
        val payload = WatchBridge.payloadOf(WatchSnapshot(claude.copy(modelWeekly = null), null, null))
        assertFalse(payload.keys.any { it.startsWith("mw") })
        assertTrue("fh" in payload)
    }

    @Test fun `a missing codex or cursor window goes as -1 with no reset`() {
        val codex = CodexWatch(fiveHour = null, weekly = Window(21.5f, 1_792_700_000_000L), fetchedAtEpochMs = 1_792_299_000_000L)
        val cursor = CursorWatch(
            plan = Window(55.2f, 1_793_500_000_000L),
            auto = null,
            api = Window(100f, 1_793_500_000_000L),
            fetchedAtEpochMs = 1_792_298_000_000L,
        )
        val payload = WatchBridge.payloadOf(WatchSnapshot(null, codex, cursor))
        assertEquals(
            mapOf(
                "xfh" to -1, "xfhr" to 0, "xwk" to 21, "xwkr" to 1_792_700_000, "xts" to 1_792_299_000,
                "upl" to 55, "uplr" to 1_793_500_000, "uau" to -1, "uaur" to 0,
                "uap" to 100, "uapr" to 1_793_500_000, "uts" to 1_792_298_000,
            ),
            payload,
        )
    }

    @Test fun `a provider with no block sends none of its keys`() {
        assertEquals(emptyMap<String, Any>(), WatchBridge.payloadOf(WatchSnapshot(null, null, null)))
    }
}
