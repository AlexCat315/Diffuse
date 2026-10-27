/** Public contract. Plugins depend on this package, never editor source. */
export { hostJob } from "./services.ts";
export type JSONValue = null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue };
export type InputType = "string" | "bool" | "number" | "integer" | { list: InputType } | { record: Record<string, InputType> }
  | { optional: InputType } | { enum: readonly string[] } | { oneOf: readonly InputType[] };
type InputValue<T> = T extends "string" ? string : T extends "bool" ? boolean
  : T extends "number" | "integer" ? number : T extends { list: infer E } ? InputValue<E>[]
  : T extends { optional: infer E } ? InputValue<E> | null | undefined
  : T extends { enum: readonly (infer E)[] } ? E
  : T extends { oneOf: readonly (infer E)[] } ? InputValue<E>
  : T extends { record: infer R } ? { [K in keyof R]: InputValue<R[K]> } : never;

export interface InvocationContext {
  readonly signal: AbortSignal;
  readonly pluginID: string;
  /** Persistent application storage owned by this plugin, shared across project hosts. */
  readonly storageDirectory: string;
  /** Shipped standalone build tools and public documentation; no editor checkout is needed. */
  readonly sdkDirectory: string;
  /** Calls a declared host service. Process and HTTP authority is checked by the editor. */
  query(permission: string, request: JSONValue): Promise<JSONValue>;
}
export interface Capability<I extends InputType = InputType> {
  input: I;
  title?: string;
  description?: string;
  run(input: InputValue<I>, context: InvocationContext): JSONValue | Promise<JSONValue>;
}
export function capability<const I extends InputType>(input: I,
  run: (input: InputValue<I>, context: InvocationContext) => JSONValue | Promise<JSONValue>,
  metadata: { title?: string; description?: string } = {}): Capability<I> {
  return { input, run, ...metadata };
}
export interface Plugin {
  capabilities: Record<string, Capability<any>>;
  activate?(scope: DisposalScope): void | Promise<void>;
  deactivate?(): void | Promise<void>;
}
export function definePlugin<P extends Plugin>(plugin: P): P { return plugin; }

/** Owns registrations, tasks and listeners; disposal is idempotent and runs in reverse order. */
export class DisposalScope {
  #disposed = false;
  #cleanups: (() => void | Promise<void>)[] = [];
  readonly controller = new AbortController();
  get signal(): AbortSignal { return this.controller.signal; }
  own(dispose: () => void | Promise<void>): void {
    if (this.#disposed) throw new Error("Plugin scope is disposed");
    this.#cleanups.push(dispose);
  }
  async dispose(): Promise<void> {
    if (this.#disposed) return;
    this.#disposed = true;
    this.controller.abort();
    const failures: unknown[] = [];
    for (const cleanup of this.#cleanups.reverse()) {
      try { await cleanup(); } catch (error) { failures.push(error); }
    }
    this.#cleanups = [];
    if (failures.length) throw new AggregateError(failures, "Plugin cleanup failed");
  }
}

/** Validates inputs at the executable boundary as well as in the editor. */
export function validateInput(value: unknown, type: InputType, path = "$"): void {
  if (typeof type === "string") {
    const valid = type === "bool" ? typeof value === "boolean"
      : type === "string" ? typeof value === "string"
      : typeof value === "number" && Number.isFinite(value) && (type !== "integer" || (Number.isSafeInteger(value) && value >= -2147483648 && value <= 2147483647));
    if (!valid) throw new Error(`${path} must be ${type}`);
  } else if ("optional" in type) {
    if (value !== undefined && value !== null) validateInput(value, type.optional, path);
  } else if ("enum" in type) {
    if (typeof value !== "string" || !type.enum.includes(value)) throw new Error(`${path} is not an allowed value`);
  } else if ("oneOf" in type) {
    let matches = 0;
    for (const child of type.oneOf) { try { validateInput(value, child, path); matches++; } catch {} }
    if (matches !== 1) throw new Error(`${path} must match exactly one alternative`);
  } else if ("list" in type) {
    if (!Array.isArray(value)) throw new Error(`${path} must be an array`);
    value.forEach((item, index) => validateInput(item, type.list, `${path}[${index}]`));
  } else {
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${path} must be an object`);
    const record = value as Record<string, unknown>;
    if (Object.keys(record).some(key => !(key in type.record))) throw new Error(`${path} has unknown fields`);
    for (const [key, child] of Object.entries(type.record)) validateInput(record[key], child, `${path}.${key}`);
  }
}
