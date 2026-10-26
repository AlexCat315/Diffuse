internal import Foundation
private import ToolSupport

/// `web-plugins` — the real browser gate for a native-validated Component
/// through Jco and an isolated Worker. Replaces
/// `Platforms/Web/Plugins/tests/browser.py`.
enum WebPluginsOperation {
  static func run(_ arguments: [String]) throws {
    var parser = FlagParser(arguments, valued: ["--host", "--probe"])
    try parser.parse()
    if parser.flags.contains("--help") {
      Terminal.info(Browser.usage)
      return
    }
    if let unexpected = parser.positionals.first {
      throw ToolError.message("unrecognized arguments: \(unexpected)")
    }
    let missing = ["--host", "--probe"].filter { parser.values[$0] == nil }
    guard missing.isEmpty else {
      throw ToolError.message(
        "the following arguments are required: \(missing.joined(separator: ", "))")
    }
    try webPlugins(
      host: absolutePath(parser.values["--host"]!),
      probe: absolutePath(parser.values["--probe"]!))
  }

  static func webPlugins(host: URL, probe: URL) throws {
    let package = Repository.path("Platforms/Web/Plugins")
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("cove-web-plugin-\(UUID().uuidString)")
    try Fs.directory(temporary)
    defer { try? Fs.remove(temporary) }

    try Fs.copyTree(
      package.appendingPathComponent("src/runtime"), to: temporary.appendingPathComponent("runtime")
    )
    try Fs.write(
      "<!doctype html><title>Cove plugin runtime gate</title>",
      to: temporary.appendingPathComponent("index.html"))
    try Shell.inherit([
      try BrowserExecutable.current().path, "plugins", "prepare",
      "--probe", probe.path, "--output", temporary.path,
    ])
    for name in ["reader", "scene-query", "infinite"] {
      try Shell.run(
        [
          "node", package.appendingPathComponent("src/packaging/entry.js").path,
          temporary.appendingPathComponent(name + ".coveplugin").path,
          temporary.appendingPathComponent(name).path,
          host.path,
        ], capture: true, echo: false)
    }

    // The application publishes this catalog from its trusted build output,
    // separately from user-uploaded plugin data.
    let names = ["reader", "scene-query", "infinite"]
    var catalog: [(String, String)] = []
    for name in names {
      let digest = try SHA256.hex(
        file: temporary.appendingPathComponent(name).appendingPathComponent("plugin.web.json"))
      catalog.append((name, digest))
    }
    let catalogText =
      "{" + catalog.map { JSON.quote($0.0) + ": " + JSON.quote($0.1) }.joined(separator: ", ") + "}"
    try Fs.write(catalogText, to: temporary.appendingPathComponent("catalog.json"))

    let server = try staticServer(directory: temporary)
    server.start()
    defer { server.stop() }

    let browser = try ChromiumBrowser.launch(executable: nil, arguments: [])
    defer { browser.close() }
    let page = try browser.newPage()
    try page.goto("http://127.0.0.1:\(server.port)/")
    Terminal.info(try page.evaluate(Self.gateScript).text)
    flushOutput()

    // Changing the executable JS after approval must be detected before import.
    let component = temporary.appendingPathComponent("reader/component.js")
    var data = try Fs.read(component)
    data.append(Data("\nthrow Error('tampered');\n".utf8))
    try Fs.write(data, to: component)
    _ = try page.evaluate(Self.tamperScript)
    Terminal.info("PASS asset tampering rejected before execution")
    flushOutput()
  }

  private static let gateScript = """
    async () => {
      const { WebPluginSession } = await import('/runtime/session.js');
      const check = (ok, name) => { if (!ok) throw Error(name); };
      const rejects = async (call, name) => { try { await call(); } catch { return; } throw Error(name); };
      const catalog = await (await fetch('/catalog.json')).json();
      const open = async name => { const url = `/${name}/plugin.web.json`; const integrity = catalog[name]; const info = await WebPluginSession.inspect(url, integrity); return WebPluginSession.open(url, {integrity, authorization: info.authorization}); };
      const reader = await open('reader');
      check((await reader.prepare('safe.reader.inspect', {enabled: true})).value === true, 'read true');
      check((await reader.prepare('safe.reader.inspect', {enabled: false})).value === false, 'fresh store false');
      await rejects(() => reader.prepare('safe.reader.inspect', {enabled: 1}), 'typed input');
      await rejects(() => reader.prepare('other.inspect', {enabled: true}), 'capability grant');
      await rejects(() => WebPluginSession.open('/reader/plugin.web.json', {integrity: catalog.reader, authorization: 'changed'}), 'authorization');
      const query = await open('scene-query');
      await rejects(() => query.prepare('safe.reader.inspect', {enabled: true}), 'missing query');
      const snapshot = { sceneRevision: 42, values: {'cove:scene/query': {entities: [], revision: 42}} };
      const value = (await query.prepare('safe.reader.inspect', {enabled: true}, {snapshot})).value;
      check(value.revision === 42 && value.entities.length === 0, 'query snapshot');
      const loop = await open('infinite');
      const start = performance.now();
      await rejects(() => loop.prepare('safe.reader.loop', {enabled: true}, {timeoutMilliseconds: 250}), 'worker deadline');
      check(performance.now() - start < 2000, 'main thread remains responsive');
      check((await reader.prepare('safe.reader.inspect', {enabled: true})).value === true, 'recovery after timeout');
      const controller = new AbortController();
      const cancelled = loop.prepare('safe.reader.loop', {enabled: true}, {signal: controller.signal});
      controller.abort(); await rejects(() => cancelled, 'cancellation');
      return 'PASS read, fresh instance, strict input, authority, query permission, Worker timeout, cancellation, recovery';
    }
    """

  private static let tamperScript = """
    async () => {
      const { WebPluginSession } = await import('/runtime/session.js');
      const integrity = (await (await fetch('/catalog.json')).json()).reader;
      const info = await WebPluginSession.inspect('/reader/plugin.web.json', integrity);
      try { await WebPluginSession.open('/reader/plugin.web.json', {integrity, authorization: info.authorization}); }
      catch (error) { if (String(error).includes('integrity')) return; throw error; }
      throw Error('Tampered code was accepted');
    }
    """
}
