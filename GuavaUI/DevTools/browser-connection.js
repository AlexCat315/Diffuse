// WebSocket-shaped adapter for an Inspector embedded in a Wasm host.
// MessagePort avoids opening a listener inside the browser sandbox.
class GuavaBrowserConnection extends EventTarget {
  readyState = 0;
  constructor() {
    super();
    if (window.parent === window) throw new Error("Browser transport requires an embedded Inspector");
    const channel = new MessageChannel();
    this.port = channel.port1;
    this.port.addEventListener("message", (event) => {
      if (event.data?.kind === "open" && this.readyState === 0) {
        this.readyState = 1;
        this.dispatchEvent(new Event("open"));
      } else if (event.data?.kind === "message" && this.readyState === 1) {
        this.dispatchEvent(new MessageEvent("message", { data: event.data.data }));
      }
    });
    this.port.start();
    window.parent.postMessage({ type: "guava.devtools.connect" }, location.origin, [channel.port2]);
  }
  send(data) {
    if (this.readyState !== 1) throw new Error("Browser transport is not connected");
    this.port.postMessage({ kind: "message", data });
  }
  close() {
    if (this.readyState === 3) return;
    this.port.postMessage({ kind: "close" });
    this.port.close();
    this.readyState = 3;
    this.dispatchEvent(new Event("close"));
  }
}
window.GuavaBrowserConnection = GuavaBrowserConnection;
