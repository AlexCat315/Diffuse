import Darwin
import EditorCore
import PlatformShell

do {
	let shell = try makeDefaultShell()
	let app = EditorApplication(shell: shell)
	try app.bootstrap()
	app.runMainLoop()
} catch {
	fputs("[EditorApp] startup failed: \(error)\n", stderr)
	exit(1)
}
