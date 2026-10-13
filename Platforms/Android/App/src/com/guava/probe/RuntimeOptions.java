package com.guava.probe;

import android.content.Intent;
import android.content.Context;
import android.util.Base64;
import java.io.File;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

/** Opt-in process diagnostics, kept outside authored launch data and checkpoints. */
final class RuntimeOptions {
    final boolean benchmark;
    final boolean timings;
    final boolean vsync;
    final boolean snapshots;
    final JSONObject devtools;

    RuntimeOptions(Context context, Intent intent) {
        benchmark = intent.getBooleanExtra("benchmark", false);
        timings = intent.getBooleanExtra("timings", false);
        vsync = intent.getBooleanExtra("vsync", true);
        snapshots = intent.getBooleanExtra("snapshots", false);
        JSONObject launch = null;
        if ((context.getApplicationInfo().flags & android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0 && intent.hasExtra("guava_devtools")) {
            try {
                launch = new JSONObject(new String(Base64.decode(intent.getStringExtra("guava_devtools"), Base64.DEFAULT), StandardCharsets.UTF_8));
                String id = launch.getString("id");
                if (!id.matches("[A-Fa-f0-9-]{36}")) throw new IllegalArgumentException("Invalid diagnostics session ID");
                launch.put("descriptorPath", new File(context.getFilesDir(), "devtools/" + id + ".json").getAbsolutePath());
            } catch (Exception error) { throw new IllegalArgumentException("Invalid diagnostics launch", error); }
        }
        devtools = launch;
    }

    static boolean updates(Intent intent) {
        return intent.hasExtra("benchmark") || intent.hasExtra("timings") || intent.hasExtra("vsync") || intent.hasExtra("snapshots") || intent.hasExtra("guava_devtools");
    }

    static void merge(Intent source, Intent destination) {
        for (String key : new String[]{"benchmark", "timings", "vsync", "snapshots"}) {
            if (source.hasExtra(key)) destination.putExtra(key, source.getBooleanExtra(key, "vsync".equals(key)));
        }
        if (source.hasExtra("guava_devtools")) destination.putExtra("guava_devtools", source.getStringExtra("guava_devtools"));
    }

    boolean sameNativeConfiguration(RuntimeOptions other) {
        return benchmark == other.benchmark && timings == other.timings && vsync == other.vsync
            && String.valueOf(devtools).equals(String.valueOf(other.devtools));
    }

    String json() {
        try {
            JSONObject value = new JSONObject();
            value.put("benchmark", benchmark);
            value.put("timings", timings);
            value.put("vsync", vsync);
            if (devtools != null) value.put("devtools", devtools);
            return value.toString();
        } catch (Exception error) { throw new IllegalStateException("Invalid runtime diagnostics", error); }
    }
}
