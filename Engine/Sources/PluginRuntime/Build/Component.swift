extension PluginComponentBuild {
    /// The guest module imports each host interface's `query` function and
    /// exports `memory`, `cabi_realloc` and one function per capability. Host
    /// functions are lowered with the guest's own memory, so they reach the
    /// guest through a table filled after it is instantiated.
    static func wat(contract: WITContract, capabilities: [(name: String, fields: [ShellField])]) -> String {
        let imports = contract.imports
        var lines = ["(component"]
        for (index, name) in imports.enumerated() {
            lines.append("""
              (import "\(name)" (instance $import\(index) \
            (export "query" (func (param "request" string) (result string)))))
              (alias export $import\(index) "query" (func $query\(index)))
            """)
        }

        lines.append("  (core module $main")
        for name in imports {
            lines.append("    (import \"\(name)\" \"query\" (func (param i32 i32 i32)))")
        }
        lines.append("    (memory (export \"memory\") 1)")
        lines.append("    (func (export \"cabi_realloc\") (param i32 i32 i32 i32) (result i32) unreachable)")
        for capability in capabilities {
            let parameters = String(repeating: " i32", count: capability.fields.count * 2)
            lines.append("    (func (export \"\(capability.name)\") (param\(parameters)) (result i32) unreachable)")
        }
        lines.append("  )")

        if imports.isEmpty {
            lines.append("  (core instance $main (instantiate $main))")
        } else {
            let slots = imports.count
            lines.append("  (core module $shim")
            lines.append("    (type $query (func (param i32 i32 i32)))")
            lines.append("    (table (export \"$imports\") \(slots) \(slots) funcref)")
            for index in imports.indices {
                lines.append("    (func (export \"\(index)\") (param i32 i32 i32) "
                    + "local.get 0 local.get 1 local.get 2 i32.const \(index) call_indirect (type $query))")
            }
            lines.append("  )")
            lines.append("  (core module $fixup")
            lines.append("    (type $query (func (param i32 i32 i32)))")
            for index in imports.indices {
                lines.append("    (import \"\" \"\(index)\" (func (type $query)))")
            }
            lines.append("    (import \"\" \"$imports\" (table \(slots) \(slots) funcref))")
            let functions = imports.indices.map(String.init).joined(separator: " ")
            lines.append("    (elem (i32.const 0) func \(functions))")
            lines.append("  )")
            lines.append("  (core instance $shim (instantiate $shim))")
            let arguments = imports.enumerated().map { index, name in
                "(with \"\(name)\" (instance (export \"query\" (func $shim \"\(index)\"))))"
            }.joined(separator: " ")
            lines.append("  (core instance $main (instantiate $main \(arguments)))")
            for index in imports.indices {
                lines.append("  (core func $lowered\(index) (canon lower (func $query\(index)) "
                    + "(memory $main \"memory\") (realloc (func $main \"cabi_realloc\"))))")
            }
            let lowered = imports.indices.map { "(export \"\($0)\" (func $lowered\($0)))" }.joined(separator: " ")
            lines.append("  (core instance (instantiate $fixup (with \"\" (instance \(lowered) "
                + "(export \"$imports\" (table $shim \"$imports\"))))))")
        }

        for (index, capability) in capabilities.enumerated() {
            let record = recordType(capability.fields)
            lines.append("  (type $input\(index) \(record))")
            lines.append("  (func $run\(index) (param \"input\" $input\(index)) (result string) "
                + "(canon lift (core func $main \"\(capability.name)\") "
                + "(memory $main \"memory\") (realloc (func $main \"cabi_realloc\"))))")
        }

        // The exported instance names each input type, as `wit-component` does.
        lines.append("  (component $exports")
        for (index, capability) in capabilities.enumerated() {
            let record = recordType(capability.fields)
            lines.append("""
                (type $local-input\(index) \(record))
                (import "input\(index)" (type $input\(index) (eq $local-input\(index))))
                (import "run\(index)" (func $run\(index) (param "input" $input\(index)) (result string)))
                (type $public-input\(index) \(record))
                (export $input-type\(index) "\(capability.name)-input" (type $public-input\(index)))
                (export "\(capability.name)" (func $run\(index)) (func (param "input" $input-type\(index)) (result string)))
            """)
        }
        lines.append("  )")
        let arguments = capabilities.indices.map {
            "(with \"input\($0)\" (type $input\($0))) (with \"run\($0)\" (func $run\($0)))"
        }.joined(separator: " ")
        lines.append("  (instance $exports (instantiate $exports \(arguments)))")
        lines.append("  (export (interface \"\(contract.capabilitiesInterfaceName)\") (instance $exports))")
        lines.append(")")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func recordType(_ fields: [ShellField]) -> String {
        let body = fields.map { "(field \"\($0.name)\" \($0.isList ? "(list string)" : "string"))" }
        return "(record \(body.joined(separator: " ")))"
    }
}
