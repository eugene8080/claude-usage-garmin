package com.usage.claudewidget.data

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WatchSnapshotTest {

    private fun fixture(): JSONObject = JSONObject(
        checkNotNull(javaClass.getResourceAsStream("/orca/accounts_snapshot.json")).reader().readText(),
    )

    private fun watchOf(snapshot: JSONObject): WatchSnapshot =
        WatchSnapshot.from(OrcaAccountsParser.parse(snapshot).usage)

    @Test fun `claude is cut from its meters, stamped with Orca's fetch time`() {
        val claude = watchOf(fixture()).claude
        assertNotNull(claude)
        claude!!
        assertEquals(12.4f, claude.fiveHour.utilization, 0.001f)
        assertEquals(1792310400000L, claude.fiveHour.resetsAtEpochMs)
        assertEquals(40.6f, claude.sevenDay.utilization, 0.001f)
        assertEquals("Fable", claude.modelWeekly?.modelName)
        // fableWeekly.resetsAt is null in the fixture: the parser borrowed the weekly reset.
        assertEquals(1792656000000L, claude.modelWeekly?.window?.resetsAtEpochMs)
        assertEquals(1792300000000L, claude.fetchedAtEpochMs)
    }

    @Test fun `codex gets both windows and its own fetch time`() {
        val codex = watchOf(fixture()).codex!!
        // 0 % with no reset is a real reading (usedPercent 0), not a missing window.
        assertEquals(Window(0f, 0L), codex.fiveHour)
        assertEquals(21.5f, codex.weekly!!.utilization, 0.001f)
        assertEquals(1792700000000L, codex.weekly!!.resetsAtEpochMs)
        assertEquals(1792299000000L, codex.fetchedAtEpochMs)
    }

    @Test fun `codex without a session window keeps its weekly one`() {
        val snapshot = fixture()
        snapshot.getJSONObject("rateLimits").getJSONObject("codex").put("session", JSONObject.NULL)
        val codex = watchOf(snapshot).codex!!
        assertNull(codex.fiveHour)
        assertEquals(21.5f, codex.weekly!!.utilization, 0.001f)
    }

    @Test fun `cursor gets plan, Auto and API, clamped to 100`() {
        val cursor = watchOf(fixture()).cursor!!
        assertEquals(55.2f, cursor.plan!!.utilization, 0.001f)
        assertEquals(1793500000000L, cursor.plan!!.resetsAtEpochMs)
        assertEquals(61f, cursor.auto!!.utilization, 0.001f)
        assertEquals(100f, cursor.api!!.utilization, 0.001f)
        assertEquals(1792298000000L, cursor.fetchedAtEpochMs)
    }

    @Test fun `a provider with no numbers has no block, and all three missing is empty`() {
        val snapshot = fixture()
        val rateLimits = snapshot.getJSONObject("rateLimits")
        rateLimits.put("cursor", JSONObject.NULL)
        val partial = watchOf(snapshot)
        assertNull(partial.cursor)
        assertFalse(partial.isEmpty)

        rateLimits.put("claude", JSONObject.NULL).put("codex", JSONObject.NULL)
        assertTrue(watchOf(snapshot).isEmpty)
    }

    @Test fun `meters stored before keys existed count as missing`() {
        val keyless = ProviderUsage(
            provider = Provider.CLAUDE,
            meters = listOf(Meter("5H", 12f, 2L), Meter("1W", 40f, 3L)),
            status = ProviderStatus.OK,
            error = null,
            updatedAtEpochMs = 1L,
        )
        assertNull(WatchSnapshot.from(mapOf(Provider.CLAUDE to keyless)).claude)
    }
}
