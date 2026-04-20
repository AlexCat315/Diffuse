import Darwin
import EditorCore
import PlatformShell
import RHIWGPU

do {
	let launchOptions = try EditorAppLaunchOptions.load()
	let shell = try makeDefaultShell()
	let app = EditorApplication(shell: shell, backendConfig: launchOptions.backendConfig)
	try app.bootstrap()
	app.runMainLoop()
} catch {
	fputs("[EditorApp] startup failed: \(error)\n", stderr)
	exit(1)
}
