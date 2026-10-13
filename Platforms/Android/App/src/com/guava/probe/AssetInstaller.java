package com.guava.probe;

import android.content.Context;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

/** APK-owned runtime assets stay separate from player saves and debug reports. */
final class AssetInstaller {
    static File root(Context context) { return new File(context.getFilesDir(), "runtime"); }
    static void unpack(Context context) throws Exception {
        File root = root(context), stamp = new File(root, ".package-version");
        String version = Long.toString(context.getPackageManager().getPackageInfo(context.getPackageName(), 0).lastUpdateTime);
        if (stamp.isFile() && new String(Files.readAllBytes(stamp.toPath()), StandardCharsets.UTF_8).equals(version)) return;
        remove(root);
        if (!root.mkdirs()) throw new IOException("Cannot create runtime asset directory");
        for (String asset : context.getAssets().list("")) copy(context, asset, root);
        Files.write(stamp.toPath(), version.getBytes(StandardCharsets.UTF_8));
    }
    private static void remove(File file) throws IOException {
        if (!file.exists()) return;
        File[] children = file.listFiles();
        if (children != null) for (File child : children) remove(child);
        if (!file.delete()) throw new IOException("Cannot replace APK asset " + file);
    }
    private static void copy(Context context, String name, File parent) throws IOException {
        String[] children = context.getAssets().list(name);
        File destination = new File(parent, new File(name).getName());
        if (children != null && children.length > 0) {
            if (!destination.mkdirs()) throw new IOException("Cannot create " + destination);
            for (String child : children) copy(context, name + "/" + child, destination);
        } else {
            try (InputStream input = context.getAssets().open(name); FileOutputStream output = new FileOutputStream(destination)) {
                byte[] buffer = new byte[16384];
                for (int length; (length = input.read(buffer)) != -1;) output.write(buffer, 0, length);
            }
        }
    }
}
