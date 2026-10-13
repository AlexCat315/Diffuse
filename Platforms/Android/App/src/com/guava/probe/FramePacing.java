package com.guava.probe;

import android.util.Log;
import java.util.Locale;

/** CPU callback statistics, not a measurement of GPU completion or presentation. */
final class FramePacing {
    private static final class Duration {
        long total, maximum;
        void add(long value) { total += value; maximum = Math.max(maximum, value); }
        void reset() { total = maximum = 0; }
        double average(int count) { return count == 0 ? 0 : (double)total / count / 1000000; }
        double maximumMillis() { return (double)maximum / 1000000; }
    }

    private final boolean enabled;
    private final Duration work = new Duration(), lag = new Duration();
    private long previousTimestamp, windowStart;
    private int callbacks, rendered, missedRefresh, overBudget, reports;

    FramePacing(boolean enabled) { this.enabled = enabled; }

    void record(long timestamp, long started, long finished, boolean presented, float refreshRate) {
        if (!enabled || reports >= 120) return;
        long period = Math.round(1000000000.0 / Math.max(1, refreshRate));
        if (windowStart == 0) windowStart = timestamp;
        if (previousTimestamp > 0 && timestamp > previousTimestamp) {
            missedRefresh += Math.max(0, (int)Math.round((double)(timestamp - previousTimestamp) / period) - 1);
        }
        previousTimestamp = timestamp;
        callbacks++;
        if (presented) rendered++;
        long duration = Math.max(0, finished - started);
        work.add(duration);
        lag.add(Math.max(0, started - timestamp));
        if (duration > period) overBudget++;
        if (timestamp - windowStart < 1000000000L) return;
        Log.i("GuavaAndroid", String.format(Locale.ROOT,
                "[timing] android.pacing refreshHz=%.3f window=%.3fms callbacks=%d rendered=%d idle=%d missedRefresh=%d overBudget=%d callbackWorkAvg=%.3fms callbackWorkMax=%.3fms callbackLagAvg=%.3fms callbackLagMax=%.3fms",
                refreshRate, (double)(timestamp - windowStart) / 1000000, callbacks, rendered, callbacks - rendered,
                missedRefresh, overBudget, work.average(callbacks), work.maximumMillis(), lag.average(callbacks), lag.maximumMillis()));
        reports++;
        windowStart = timestamp;
        callbacks = rendered = missedRefresh = overBudget = 0;
        work.reset(); lag.reset();
    }
}
