#!/usr/bin/env python3
"""
Merge compile_commands.json files from engine (Zig) and Qt (CMake).
Used to provide clangd with complete compilation info for both subsystems.
"""

import json
import sys
import os
from pathlib import Path

def merge_compile_commands():
    # Get the workspace root (where we run zig build from)
    # The script is called from root via "python3 build/merge_compile_commands.py"
    # So we need to find the actual root directory
    
    # Try multiple approaches to find root
    if os.path.exists("compile_commands.json") and os.path.exists("packages/editor_qt"):
        root_dir = Path.cwd()
    else:
        root_dir = Path(__file__).parent.parent.parent
    
    engine_db = root_dir / "compile_commands.json"
    qt_db = root_dir / "packages" / "editor_qt" / "build" / "compile_commands.json"
    output_db = root_dir / "compile_commands.json"
    
    print(f"📍 Using root directory: {root_dir}", file=sys.stderr)
    print(f"   Engine DB: {engine_db}", file=sys.stderr)
    print(f"   Qt DB: {qt_db}", file=sys.stderr)
    
    # Load engine compile_commands.json
    if not engine_db.exists():
        print(f"⚠️  Engine compile_commands.json not found at {engine_db}")
        return False
    
    with open(engine_db) as f:
        engine_commands = json.load(f)
    
    # Load Qt compile_commands.json if it exists
    qt_commands = []
    if qt_db.exists():
        try:
            with open(qt_db) as f:
                qt_commands = json.load(f)
            print(f"✓ Merged {len(qt_commands)} Qt compilation commands", file=sys.stderr)
        except (json.JSONDecodeError, IOError) as e:
            print(f"⚠️  Could not read Qt compile_commands.json: {e}", file=sys.stderr)
    else:
        print(f"⚠️  Qt compile_commands.json not found at {qt_db}", file=sys.stderr)
    
    # Merge
    merged = engine_commands + qt_commands
    
    # Write merged compile_commands.json
    with open(output_db, 'w') as f:
        json.dump(merged, f, indent=2)
        f.write('\n')
    
    print(f"✓ Merged compile_commands.json with {len(merged)} total entries", file=sys.stderr)
    print(f"  - Engine (Zig): {len(engine_commands)} commands", file=sys.stderr)
    print(f"  - Qt (CMake): {len(qt_commands)} commands", file=sys.stderr)
    
    return True

if __name__ == "__main__":
    success = merge_compile_commands()
    sys.exit(0 if success else 1)

