import EditorCore
import PlatformShell

let shell = MacShell()
let app = EditorApplication(shell: shell)
app.bootstrap()
app.runMainLoop(iterations: 240)
