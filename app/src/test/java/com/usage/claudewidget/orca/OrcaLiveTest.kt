package com.usage.claudewidget.orca

import com.usage.claudewidget.data.OrcaAccountsParser
import com.usage.claudewidget.data.Provider
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * One real `accounts.list` call to a running desktop Orca - the check that the port still
 * speaks the protocol of the Orca build actually installed. Skipped unless a pairing code is
 * given, so CI never runs it:
 *
 * ```
 * ORCA_PAIRING_CODE='orca://pair?code=...' [ORCA_ENDPOINT=ws://127.0.0.1:6768] \
 *     ./gradlew :app:testDebugUnitTest --tests '*OrcaLiveTest*' -i
 * ```
 *
 * ORCA_ENDPOINT overrides the code's address, e.g. loopback when testing on the computer
 * that runs Orca. It prints each provider's meters, never the token or account details.
 */
class OrcaLiveTest {

    @Test fun `accounts list from a live desktop Orca`() = runBlocking {
        val code = System.getenv("ORCA_PAIRING_CODE")
        assumeTrue("ORCA_PAIRING_CODE not set", !code.isNullOrBlank())
        val parsed = OrcaPairingCodec.parse(code!!)
        assertTrue("pairing code: $parsed", parsed is OrcaPairingCodec.ParseResult.Ok)
        var pairing = (parsed as OrcaPairingCodec.ParseResult.Ok).pairing
        System.getenv("ORCA_ENDPOINT")?.let { override ->
            pairing = pairing.copy(endpoint = checkNotNull(OrcaPairingCodec.normalizeEndpoint(override)))
        }

        val result = OrcaClient().call(pairing, "accounts.list", JSONObject().put("refreshUsage", true))
        println("accounts.list via ${pairing.endpoint}: ${result.javaClass.simpleName}")
        assertTrue("got $result", result is OrcaCallResult.Ok)

        val snapshot = (result as OrcaCallResult.Ok).result
        val accounts = OrcaAccountsParser.parse(snapshot)
        Provider.entries.forEach { provider ->
            println(OrcaAccountsParser.summarize(accounts.usage.getValue(provider)))
        }
        println("watch: ${accounts.claudeWatch}")

        // The raw windows behind those rows, to check the mapping against what Orca sent.
        // Only window fields and status: the blocks' metadata can name credential sources.
        val rateLimits = (snapshot as JSONObject).getJSONObject("rateLimits")
        Provider.entries.forEach { provider ->
            val block = rateLimits.optJSONObject(provider.orcaKey)
            if (block == null) {
                println("raw ${provider.orcaKey}: null")
                return@forEach
            }
            val windows = WINDOW_SLOTS.filter { block.has(it) }.joinToString(", ") { slot ->
                val window = block.optJSONObject(slot)
                if (window == null) "$slot=null" else "$slot={used=${window.opt("usedPercent")}, " +
                    "minutes=${window.opt("windowMinutes")}, resetsAt=${window.opt("resetsAt")}}"
            }
            val buckets = block.optJSONArray("buckets")?.let { list ->
                (0 until list.length()).joinToString(", ", " buckets=[", "]") { i ->
                    val bucket = list.getJSONObject(i)
                    "${bucket.opt("name")}=${bucket.opt("usedPercent")}"
                }
            }.orEmpty()
            println("raw ${provider.orcaKey}: status=${block.opt("status")} error=${block.opt("error")} $windows$buckets")
        }
    }

    private companion object {
        val WINDOW_SLOTS = listOf("session", "weekly", "fableWeekly", "monthly")
    }
}
