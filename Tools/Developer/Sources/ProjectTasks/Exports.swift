private import Foundation
private import ToolSupport

public enum ProjectExportTask {
    public static func run(_ arguments: [String]) throws { try AndroidExport.run(arguments) }
}

public enum ProjectPluginTask {
    public static func run(_ arguments: [String]) throws {
        guard let directory = arguments.first else { throw ToolError.message("Supply a plugin directory") }
        let options = Array(arguments.dropFirst())
        guard options.isEmpty || (options.count == 2 && options[0] == "--output") else {
            throw ToolError.message("Use guava task plugin-build -- DIRECTORY [--output PACKAGE.guavaplugin]")
        }
        try PluginBuild(directory: URL(fileURLWithPath: directory), root: Repository.root,
                        output: options.last.map { URL(fileURLWithPath: $0) }).run()
    }
}
