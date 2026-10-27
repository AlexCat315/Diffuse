import type { InvocationContext, JSONValue } from "./index.ts";
export type Step = Record<string, any>;
export interface StepRequest {
  op: string; next?: string; output?: { exit: number; stderr: string; offset?: number; complete?: boolean };
  [key: string]: any;
}
export const result = (value: unknown): Step => ({ result: value });
export const failure = (error: string): Step => ({ error });
export const run = (args: string[], next?: string, options: Step = {}): Step => ({ run: args, ...(next ? { next } : {}), ...options });
export const whole = (next = "parse"): Step => ({ emit: "", consumed: 0, next });
export const complete = (request: StepRequest, stdout: string): Step => request.output?.exit === 0
  ? result(null) : failure((request.output?.stderr || stdout || "Command failed").trim().slice(-2000));
export const validBranch = (name: string): boolean => !!name && !name.startsWith("-") && !name.startsWith("/")
  && !name.endsWith("/") && !name.endsWith(".") && !name.includes("..") && !name.includes("@{")
  && !/[\x00-\x20\x7f~^:?*\[\\]/.test(name) && name !== "@"
  && name.split("/").every(part => !!part && !part.startsWith(".") && !part.endsWith(".lock"));
export async function serve(request: string, stdout: string, context: InvocationContext,
  handle: (request: StepRequest, stdout: string) => Step): Promise<JSONValue> {
  const value = JSON.parse(request);
  if (value.process) return context.query("cove:process/host", value.process);
  if (typeof value.op !== "string") throw new Error("Missing operation");
  return handle(value, stdout) as JSONValue;
}
