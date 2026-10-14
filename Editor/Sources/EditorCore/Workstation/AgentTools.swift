import Foundation
import MediaRuntime

extension EditorApplication {
    @MainActor
    func executeWorkstationTool(_ name: String, arguments: [String: Any]) async throws -> [String: Any]? {
        switch name {
        case "list_files": return ["files": workstation.documents.files()]
        case "read_file":
            let document = try workstation.documents.read(arguments["path"] as! String)
            return ["path": document.path, "text": document.text, "exists": document.existsOnDisk, "dirty": document.isDirty]
        case "write_file":
            try workstation.documents.write(arguments["path"] as! String, text: arguments["text"] as! String,
                                             expected: arguments["expected_text"] as? String)
            return ["ok": true]
        case "get_media_timeline":
            return try JSONSerialization.jsonObject(with: JSONEncoder().encode(workstation.media.composition)) as? [String: Any]
        case "add_media_clip": try workstation.media.add(arguments["path"] as! String)
        case "trim_media_clip":
            try workstation.media.trim(arguments["index"] as! Int, start: arguments["start"] as! Double,
                                       duration: arguments["duration"] as! Double)
        case "remove_media_clip": workstation.media.remove(arguments["index"] as! Int)
        case "save_media_timeline":
            guard workstation.media.save() else { throw EditorProjectToolError(workstation.media.error ?? "Media save failed") }
        case "export_media":
            let directory = URL(fileURLWithPath: projectDirectory).appendingPathComponent("Exports")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let output = directory.appendingPathComponent("video-\(UUID().uuidString).mp4")
            try await workstation.media.export(to: output, executable: FFmpegTools.executable())
            return ["ok": true, "output": output.path]
        default: return nil
        }
        return ["ok": true]
    }
}
