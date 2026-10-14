#!/usr/bin/env python3
"""Run the portable Component execution/fuel gate against a staged native runtime."""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="guava-plugin-probe-") as temporary:
        fixtures = Path(temporary)
        subprocess.run([sys.executable, str(Path(__file__).with_name("prepare.py")),
                        "--probe", str(args.probe.resolve()), "--output", str(fixtures)], check=True)
        paths = [str(fixtures / (name + ".guavaplugin/component.wasm")) for name in ["reader", "scene-query", "infinite"]]
        for mode in ["native", "pulley"]:
            subprocess.run([str(args.probe.resolve()), *paths, mode], check=True)


if __name__ == "__main__":
    main()
