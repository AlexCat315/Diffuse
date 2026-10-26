import CovePluginKit

/// SourceKit-LSP runs on the host under the manifest's `language-server`
/// permission. The editor drives it with process requests (start, write,
/// poll, stop), which this forwards unchanged; the host checks each one.
func languageServer(request: String) -> String {
    CoveHost.process(request)
}
