package com.usage.claudewidget.work

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.usage.claudewidget.data.FetchResult
import com.usage.claudewidget.data.UsageRepository
import com.usage.claudewidget.watch.WatchBridge
import com.usage.claudewidget.widget.ProviderUsageWidget

/** Fetches usage from desktop Orca in the background and fans it out to the widgets and the watch. */
class RefreshWorker(context: Context, params: WorkerParameters) :
    CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val result = UsageRepository(applicationContext).refresh()
        // Usage + link state are already persisted by the repository; just re-render.
        ProviderUsageWidget.updateAll(applicationContext)

        // The watch is a second consumer of the Claude numbers, and a strictly optional one:
        // it has no credentials and cannot fetch for itself, but a watch that is out of
        // range must not turn a successful refresh into a retry. Only push on a fresh
        // fetch - re-sending an unchanged snapshot would spend radio for nothing.
        val claude = (result as? FetchResult.Success)?.claudeWatch
        if (claude != null) {
            when (val push = WatchBridge.push(applicationContext, claude)) {
                is WatchBridge.PushResult.Sent -> Log.i(TAG, "watch updated: ${push.deviceName}")
                else -> Log.i(TAG, "watch not updated: $push")
            }
        }

        return when (result) {
            is FetchResult.Success, is FetchResult.NeedsPairing -> Result.success()
            // A computer that is off stays off for a while: wait for the next 15-minute run
            // rather than piling up retries, whose backoff only pushes the next real run out
            // (see RefreshScheduler's backlog guard). Retry only what can clear in a minute.
            is FetchResult.Soft -> if (result.retry) Result.retry() else Result.success()
        }
    }

    private companion object {
        const val TAG = "ClaudeWatch"
    }
}
