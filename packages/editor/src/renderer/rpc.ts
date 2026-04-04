import type { RpcMethodName, RpcParams, RpcResult } from "../shared/rpc-types";

export function rpc<M extends RpcMethodName>(
  method: M,
  params: RpcParams<M>,
): Promise<RpcResult<M>> {
  return window.guavaEngine.call(method, params);
}
