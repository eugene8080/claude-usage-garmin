package com.usage.claudewidget.data

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OrcaAccountsParserTest {

    private fun fixture(): JSONObject = JSONObject(
        checkNotNull(javaClass.getResourceAsStream("/orca/accounts_snapshot.json")).reader().readText(),
    )

    private fun labels(usage: ProviderUsage) = usage.meters.map { it.label }

    @Test fun `claude gets 5H, 1W and 1W Fable with the pooled reset borrowed`() {
        val claude = OrcaAccountsParser.parse(fixture()).usage.getValue(Provider.CLAUDE)
        assertEquals(listOf("5H", "1W", "1W Fable"), labels(claude))
        assertEquals(12.4f, claude.meters[0].utilization, 0.001f)
        assertEquals(1792310400000L, claude.meters[0].resetsAtEpochMs)
        // fableWeekly.resetsAt is null: it takes the weekly pool's reset.
        assertEquals(1792656000000L, claude.meters[2].resetsAtEpochMs)
        assertEquals(ProviderStatus.OK, claude.status)
        assertEquals(1792300000000L, claude.updatedAtEpochMs)
    }

    @Test fun `every meter carries the key of the Orca window it came from`() {
        val usage = OrcaAccountsParser.parse(fixture()).usage
        assertEquals(listOf("session", "weekly", "fableWeekly"), usage.getValue(Provider.CLAUDE).meters.map { it.key })
        assertEquals(listOf("session", "weekly"), usage.getValue(Provider.CODEX).meters.map { it.key })
        assertEquals(
            listOf("monthly", "bucket:Cursor Models", "bucket:Other Models"),
            usage.getValue(Provider.CURSOR).meters.map { it.key },
        )
    }

    @Test fun `a snapshot stored before keys existed still reads, with empty keys`() {
        val old = """{"provider":"CLAUDE","status":"OK","error":null,"updatedAt":1,""" +
            """"meters":[{"label":"5H","pct":12.0,"resetsAt":2}]}"""
        assertEquals("", ProviderUsage.fromJson(old)!!.meters.single().key)
    }

    @Test fun `codex gets 5H and 1W`() {
        val codex = OrcaAccountsParser.parse(fixture()).usage.getValue(Provider.CODEX)
        assertEquals(listOf("5H", "1W"), labels(codex))
        assertEquals(0L, codex.meters[0].resetsAtEpochMs)
        assertEquals(21.5f, codex.meters[1].utilization, 0.001f)
    }

    @Test fun `cursor gets its plan and the first two pools, clamped to 100`() {
        val cursor = OrcaAccountsParser.parse(fixture()).usage.getValue(Provider.CURSOR)
        // Plan + Auto + API fill the three rows; On-demand is the fourth and is left out.
        assertEquals(listOf("Plan", "Auto", "API"), labels(cursor))
        assertEquals(100f, cursor.meters[2].utilization, 0.001f)
        assertEquals(1793500000000L, cursor.meters[0].resetsAtEpochMs)
    }

    @Test fun `the watch snapshot is Claude's, stamped with Orca's fetch time`() {
        val watch = OrcaAccountsParser.parse(fixture()).claudeWatch
        assertNotNull(watch)
        watch!!
        assertEquals(12.4f, watch.fiveHour.utilization, 0.001f)
        assertEquals(40.6f, watch.sevenDay.utilization, 0.001f)
        assertEquals("Fable", watch.modelWeekly?.modelName)
        assertEquals(1792656000000L, watch.modelWeekly?.window?.resetsAtEpochMs)
        assertEquals(1792300000000L, watch.fetchedAtEpochMs)
    }

    @Test fun `a provider Orca has no block for is not set up`() {
        val snapshot = fixture()
        snapshot.getJSONObject("rateLimits").put("cursor", JSONObject.NULL)
        val cursor = OrcaAccountsParser.parse(snapshot).usage.getValue(Provider.CURSOR)
        assertEquals(ProviderStatus.NOT_SET_UP, cursor.status)
        assertTrue(cursor.meters.isEmpty())
    }

    @Test fun `an error with no windows keeps the error and no meters`() {
        val snapshot = fixture()
        snapshot.getJSONObject("rateLimits").put(
            "claude",
            JSONObject()
                .put("provider", "claude")
                .put("session", JSONObject.NULL)
                .put("weekly", JSONObject.NULL)
                .put("updatedAt", 0)
                .put("error", "Claude Code is not signed in")
                .put("status", "unavailable"),
        )
        val parsed = OrcaAccountsParser.parse(snapshot)
        val claude = parsed.usage.getValue(Provider.CLAUDE)
        assertEquals(ProviderStatus.UNAVAILABLE, claude.status)
        assertEquals("Claude Code is not signed in", claude.error)
        assertTrue(claude.meters.isEmpty())
        assertNull(parsed.claudeWatch)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `a result without rateLimits is refused`() {
        OrcaAccountsParser.parse(JSONObject().put("claude", JSONObject()))
    }

    @Test fun `stored usage round-trips through JSON`() {
        val claude = OrcaAccountsParser.parse(fixture()).usage.getValue(Provider.CLAUDE)
        assertEquals(claude, ProviderUsage.fromJson(claude.toJson()))
        val failed = claude.copy(status = ProviderStatus.ERROR, error = "boom")
        assertEquals(failed, ProviderUsage.fromJson(failed.toJson()))
        assertNull(ProviderUsage.fromJson("{}"))
    }
}
