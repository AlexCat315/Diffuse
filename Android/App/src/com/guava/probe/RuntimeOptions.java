package com.guava.probe;

import android.content.Intent;
import org.json.JSONObject;

/** Opt-in process diagnostics, kept outside authored launch data and checkpoints. */
final class RuntimeOptions {
    final boolean benchmark;
    final boolean timings;
    final boolean vsync;
    final boolean snapshots;

    RuntimeOptions(Intent intent) {
        benchmark = intent.getBooleanExtra("benchmark", false);
        timings = intent.getBooleanExtra("timings", false);
        vsync = intent.getBooleanExtra("vsync", true);
        snapshots = intent.getBooleanExtra("snapshots", false);
    }

    static boolean updates(Intent intent) {
        return intent.hasExtra("benchmark") || intent.hasExtra("timings") || intent.hasExtra("vsync") || intent.hasExtra("snapshots");
    }

    static void merge(Intent source, Intent destination) {
        for (String key : new String[]{"benchmark", "timings", "vsync", "snapshots"}) {
            if (source.hasExtra(key)) destination.putExtra(key, source.getBooleanExtra(key, "vsync".equals(key)));
        }
    }

    boolean sameNativeConfiguration(RuntimeOptions other) {
        return benchmark == other.benchmark && timings == other.timings && vsync == other.vsync;
    }

    String json() {
        try {
            JSONObject value = new JSONObject();
            value.put("benchmark", benchmark);
            value.put("timings", timings);
            value.put("vsync", vsync);
            return value.toString();
        } catch (Exception error) { throw new IllegalStateException("Invalid runtime diagnostics", error); }
    }
}
