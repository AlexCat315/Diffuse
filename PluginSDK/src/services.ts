import type { InvocationContext, JSONValue } from "./index.ts";

/** Long-running native and cross-plugin work never blocks a renderer request. */
export async function hostJob(context: InvocationContext, permission: string, request: Record<string, JSONValue>, signal = context.signal): Promise<JSONValue> {
  signal.throwIfAborted();
  const started = await context.query(permission, { ...request, operation: request.operation ?? "start" }) as { job: string };
  if (!started?.job) throw new Error("Host did not return a job");
  let completed = false;
  try {
    while (true) {
      signal.throwIfAborted();
      const result = await context.query(permission, { operation: "poll", job: started.job }) as { status: string; value: JSONValue; error: string };
      if (result.status === "completed") { completed = true; return result.value; }
      if (result.status === "failed") { completed = true; throw new Error(result.error); }
      await new Promise<void>((resolve, reject) => {
        const stop = () => { clearTimeout(timer); reject(signal.reason); };
        const timer = setTimeout(() => { signal.removeEventListener("abort", stop); resolve(); }, 100);
        signal.addEventListener("abort", stop, { once: true });
        if (signal.aborted) stop();
      });
    }
  } finally {
    if (!completed) await context.query(permission, { operation: "cancel", job: started.job }).catch(() => {});
  }
}
