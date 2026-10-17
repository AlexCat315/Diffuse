internal import Foundation
private import ToolSupport

/// A parsed HTTP/1.x request. The static server and the development server
/// share this shape so routing matches `http.server`'s `SimpleHTTPRequestHandler`.
struct HTTPRequest: Sendable {
  var method: String
  var target: String
  var rawPath: String
  var path: String
  var query: String
  var version: String
  var headers: [String: String]
  var body: Data

  var isHead: Bool { method == "HEAD" }
}

extension HTTPRequest {
  /// Parses the request line and headers, matching `BaseHTTPRequestHandler`'s
  /// lenient splitting of `HEAD /path HTTP/1.1` and `Name: value` lines.
  static func parse(head: Data, body: Data) -> HTTPRequest? {
    guard let text = String(data: head, encoding: .utf8) else { return nil }
    var lines = text.components(separatedBy: "\r\n")
    guard let request = lines.first else { return nil }
    lines.removeFirst()
    let parts = request.split(separator: " ")
    guard parts.count >= 2 else { return nil }
    let method = String(parts[0])
    let target = String(parts[1])
    let version = parts.count >= 3 ? String(parts[2]) : "HTTP/1.0"
    var headers: [String: String] = [:]
    for line in lines where !line.isEmpty {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
      let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      headers[name] = value
    }
    let queryStart = target.firstIndex(of: "?")
    let rawPath = queryStart.map { String(target[..<$0]) } ?? target
    let query = queryStart.map { String(target[target.index(after: $0)...]) } ?? ""
    return HTTPRequest(
      method: method, target: target, rawPath: rawPath,
      path: rawPath.removingPercentEncoding ?? rawPath,
      query: query, version: version, headers: headers, body: body)
  }
}

/// A blocking writer for one connection. `stream` keeps the socket open so the
/// development server can hold an `EventSource` connection like `http.server`'s
/// HTTP/1.0 response does.
final class HTTPStream: @unchecked Sendable {
  private let writer: (Data) -> Bool

  init(writer: @escaping (Data) -> Bool) { self.writer = writer }

  @discardableResult
  func write(_ text: String) -> Bool { writer(Data(text.utf8)) }

  @discardableResult
  func write(_ data: Data) -> Bool { writer(data) }
}

/// Writes one HTTP/1.0 response. `Content-Length` is always present so clients
/// do not need `Connection: close` to delimit the body, and every response
/// closes the connection exactly like `http.server`'s default protocol version.
final class HTTPResponse: @unchecked Sendable {
  private let writer: (Data) -> Bool
  private(set) var status = 200
  private var sent = false

  init(writer: @escaping (Data) -> Bool) { self.writer = writer }

  @discardableResult
  private func writeHead(status: Int, reason: String, headers: [String: String]) -> Bool {
    self.status = status
    var head = "HTTP/1.0 \(status) \(reason)\r\n"
    var all = headers
    all["Connection"] = "close"
    for (name, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
    head += "\r\n"
    sent = true
    return writer(Data(head.utf8))
  }

  func send(
    status: Int, reason: String = "", headers: [String: String] = [:], body: Data = Data(),
    isHead: Bool = false
  ) {
    var all = headers
    all["Content-Length"] = String(body.count)
    _ = writeHead(
      status: status, reason: reason.isEmpty ? HTTPStatus.reason(status) : reason, headers: all)
    if !isHead, !body.isEmpty { _ = writer(body) }
  }

  func text(
    _ body: String, status: Int = 200, contentType: String = "text/html; charset=utf-8",
    isHead: Bool = false
  ) {
    send(
      status: status, headers: ["Content-Type": contentType], body: Data(body.utf8), isHead: isHead)
  }

  func redirect(_ location: String) {
    _ = writeHead(
      status: 301, reason: HTTPStatus.reason(301),
      headers: ["Location": location, "Content-Length": "0"])
  }

  func sendError(_ code: Int, _ message: String) {
    let body = """
      <!DOCTYPE HTML>
      <html lang="en">
      <head><meta charset="utf-8"><title>Error response</title></head>
      <body><h1>Error response</h1><p>Error code: \(code)</p><p>Message: \(message).</p></body>
      </html>
      """
    text(body, status: code, contentType: "text/html; charset=utf-8")
  }

  func sendFile(_ url: URL, isHead: Bool) {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = (attributes[.size] as? NSNumber)?.intValue
    else {
      sendError(404, "File not found")
      return
    }
    var headers = ["Content-Type": StaticFiles.contentType(for: url.path)]
    headers["Content-Length"] = String(size)
    _ = writeHead(status: 200, reason: HTTPStatus.reason(200), headers: headers)
    guard !isHead else { return }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? handle.close() }
    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      if !writer(chunk) { return }
    }
  }

  /// Streams a response without `Content-Length`; the body closure writes until
  /// the peer disconnects, matching an `EventSource` response.
  func stream(headers: [String: String], _ body: (HTTPStream) -> Void) {
    _ = writeHead(status: 200, reason: HTTPStatus.reason(200), headers: headers)
    body(HTTPStream(writer: writer))
  }
}

enum HTTPStatus {
  static func reason(_ code: Int) -> String {
    switch code {
    case 200: return "OK"
    case 301: return "Moved Permanently"
    case 302: return "Found"
    case 400: return "Bad Request"
    case 403: return "Forbidden"
    case 404: return "File not found"
    case 405: return "Method Not Allowed"
    case 500: return "Internal Server Error"
    case 501: return "Unsupported method ('POST')"
    default: return "Unknown"
    }
  }
}

/// Serves a directory the way `functools.partial(QuietHandler, directory=...)`
/// does: index.html for directories, a redirect when the trailing slash is
/// missing, and a small listing otherwise.
enum StaticFiles {
  static func respond(_ request: HTTPRequest, _ response: HTTPResponse, directory: URL) {
    guard request.method == "GET" || request.method == "HEAD" else {
      response.sendError(501, "Unsupported method ('\(request.method)')")
      return
    }
    var safe: [String] = []
    for component in request.path.split(separator: "/", omittingEmptySubsequences: true) {
      let part = String(component)
      if part == "." { continue }
      if part == ".." {
        if !safe.isEmpty { safe.removeLast() }
        continue
      }
      safe.append(part)
    }
    var file = directory
    for component in safe { file.appendPathComponent(component) }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
      response.sendError(404, "File not found")
      return
    }
    if isDirectory.boolValue {
      if !request.rawPath.hasSuffix("/") {
        response.redirect(
          request.rawPath + "/" + (request.query.isEmpty ? "" : "?" + request.query))
        return
      }
      let index = file.appendingPathComponent("index.html")
      if FileManager.default.fileExists(atPath: index.path) {
        response.sendFile(index, isHead: request.isHead)
      } else {
        list(file, request: request, response: response)
      }
      return
    }
    response.sendFile(file, isHead: request.isHead)
  }

  private static func list(_ directory: URL, request: HTTPRequest, response: HTTPResponse) {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    var rows = ""
    for name in entries.sorted() {
      let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
      rows += "<li><a href=\"\(escaped)\">\(name)</a></li>\n"
    }
    let title = "Directory listing for \(request.path)"
    response.text(
      "<!DOCTYPE HTML>\n<html lang=\"en\">\n<head><meta charset=\"utf-8\"><title>\(title)</title></head>\n"
        + "<body><h1>\(title)</h1><hr><ul>\(rows)</ul><hr></body>\n</html>\n")
  }

  static func contentType(for path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "html", "htm": return "text/html"
    case "js", "mjs": return "text/javascript"
    case "css": return "text/css"
    case "json", "webmanifest": return "application/json"
    case "map": return "application/json"
    case "wasm": return "application/wasm"
    case "wat", "txt", "md": return "text/plain"
    case "ttf": return "font/ttf"
    case "otf": return "font/otf"
    case "woff": return "font/woff"
    case "woff2": return "font/woff2"
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "svg": return "image/svg+xml"
    case "ico": return "image/vnd.microsoft.icon"
    case "xml": return "text/xml"
    default: return "application/octet-stream"
    }
  }
}
