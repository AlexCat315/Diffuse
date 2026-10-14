#!/usr/bin/env python3
"""Build shared Component fixtures using the same Wasmtime C API as production."""
import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    fixtures = Path(__file__).resolve().parents[2] / "Tests/PluginRuntimeTests/Fixtures"
    for name, capability, imports in [("reader", "inspect", []), ("scene-query", "inspect", ["guava:scene/query"]), ("infinite", "loop", [])]:
        package = args.output / (name + ".guavaplugin")
        package.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(args.probe.resolve()), "--compile", str(fixtures / (name + ".wat")), str(package / "component.wasm")], check=True)
        (package / "plugin.json").write_text(json.dumps(dict(id="safe.reader", version=1, name="Reader", description="Cross-platform fixture", access="read", imports=imports, composable_host_capabilities=[])))
        (package / "capabilities.wit").write_text(f"package safe:reader; interface capabilities {{ record {capability}-input {{ enabled: bool }} {capability}: func(input: {capability}-input) -> string; }} world plugin {{ " + "".join("import " + name + ";" for name in imports) + " export capabilities; }")


if __name__ == "__main__":
    main()
