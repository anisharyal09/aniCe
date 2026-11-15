// SPDX-License-Identifier: GPL-3.0-or-later
// Schedules a network-constrained daily release refresh at 19:30 Nepal time with overdue catch-up.
package io.github.anisharyal09.anice.update

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import io.github.anisharyal09.anice.AniCeApplication
import kotlinx.coroutines.*

internal object UpdateSchedule {
    const val DAY = 86_400_000L
    private const val NEPAL_EVENING_UTC = 49_500_000L // 19:30 UTC+05:45 is 13:45 UTC.

    fun latestEvening(now: Long): Long = Math.floorDiv(now - NEPAL_EVENING_UTC, DAY) * DAY + NEPAL_EVENING_UTC

    fun retryDelay(failures: Int): Long =
        if (failures <= 0) 0L else (900_000L shl (failures.coerceAtMost(7) - 1)).coerceAtMost(DAY)

    fun nextCheck(now: Long, lastSuccess: Long, lastAttempt: Long, failures: Int): Long {
        val evening = latestEvening(now)
        val completed = lastSuccess in evening..now
        val deadline = if (completed) evening + DAY else evening
        val retry = if (lastAttempt in 1..now && failures > 0) lastAttempt + retryDelay(failures) else 0L
        return maxOf(now, deadline, retry)
    }
}

internal fun scheduleUpdateCheck(context: Context, at: Long) {
    if (context.packageName != "io.github.anisharyal09.anice") return
    val job = JobInfo.Builder(UPDATE_JOB_ID, ComponentName(context, UpdateCheckService::class.java))
        .setMinimumLatency((at - System.currentTimeMillis()).coerceAtLeast(0L))
        .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
        .setBackoffCriteria(900_000L, JobInfo.BACKOFF_POLICY_EXPONENTIAL)
        .setPersisted(true)
        .build()
    context.getSystemService(JobScheduler::class.java).schedule(job)
}

private const val UPDATE_JOB_ID = 730

class UpdateCheckService : JobService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var work: Job? = null
    private var active: JobParameters? = null
    private var check: Job? = null

    override fun onStartJob(params: JobParameters): Boolean {
        active = params
        work = scope.launch {
            val updates = (application as AniCeApplication).updates
            check = updates.check()
            check?.join()
            ensureActive()
            if (active?.jobId != params.jobId) return@launch
            active = null
            check = null
            jobFinished(params, false)
            updates.scheduleNextCheck()
        }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        if (active?.jobId != params.jobId) return false
        work?.cancel()
        (application as AniCeApplication).updates.stopBackgroundCheck(check)
        work = null
        active = null
        check = null
        return true
    }

    override fun onDestroy() {
        scope.cancel()
        (application as AniCeApplication).updates.stopBackgroundCheck(check)
        super.onDestroy()
    }
}

class UpdateClockReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_TIME_CHANGED || intent.action == Intent.ACTION_TIMEZONE_CHANGED) {
            (context.applicationContext as AniCeApplication).updates.scheduleNextCheck()
        }
    }
}
