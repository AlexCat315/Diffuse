import type { RpcMethodName, RpcParams, RpcResult } from "../shared/rpc-types";
import { engine } from "./engine-client";

export function rpc<M extends RpcMethodName>(
  method: M,
  params: RpcParams<M>,
): Promise<RpcResult<M>> {
  return engine.call(method, params) as Promise<RpcResult<M>>;
}
