package com.guava.probe;

/** Java and JNI records use the same Swift backend as the engine. */
final class RuntimeLog {
    static native void flush();
    static native void write(int level, String label, String message);
    static void info(String label, String message) { write(2, label, message); }
    static void error(String label, String message) { write(5, label, message); }
}
