export type QueryPermission = 'guava:scene/query' | 'guava:selection/query' | 'guava:asset/metadata-query';
export type Access = 'read' | 'reversible_write' | 'destructive_write';
export interface Inspection {
  manifest: {
    id: string;
    version: number;
    name: string;
    description: string;
    access: Access;
    imports: QueryPermission[];
    composable_host_capabilities: string[];
  };
  componentHash: string;
  witHash: string;
  contracts: Array<{
    id: string;
    version: number;
    title: string;
    description: string;
    access: Access;
    inputSchema: Record<string, unknown>;
    schemaHash: string;
  }>;
}
export interface InvocationOptions {
  snapshot?: { sceneRevision: number; values: Partial<Record<QueryPermission, object>> };
  signal?: AbortSignal;
  /** May lower the five second maximum. */
  timeoutMilliseconds?: number;
}
export type PreparedResult =
  | { kind: 'read'; value: unknown }
  | { kind: 'hostCalls'; calls: Array<{ capabilityID: string; version: number; arguments: string }> };
export declare class WebPluginSession {
  private constructor();
  /** integrity must come from the application's trusted build catalog. */
  static inspect(url: string | URL, integrity: string): Promise<{ inspection: Inspection; authorization: string }>;
  static open(url: string | URL, approval: { integrity: string; authorization: string }): Promise<WebPluginSession>;
  prepare(capabilityID: string, input: unknown, options?: InvocationOptions): Promise<PreparedResult>;
}
