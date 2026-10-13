#!/usr/bin/env python3
"""Validate application, platform and example dependency boundaries via SwiftPM."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def manifest(path, **overrides):
    environment = dict(os.environ)
    for key in ("GUAVA_ANDROID_UI_PACKAGE", "GUAVA_ANDROID_GAME_PACKAGE"):
        environment.pop(key, None)
    environment.update(overrides)
    result = subprocess.run([environment.get("GUAVA_SWIFT_EXECUTABLE", "swift"), "package", "--package-path", str(ROOT / path), "dump-package"],
                            env=environment, check=True, text=True, capture_output=True)
    return json.loads(result.stdout)


def local_dependencies(package):
    return {Path(item["fileSystem"][0]["path"]).resolve() for item in package["dependencies"] if "fileSystem" in item}


def check():
    ui = manifest("GuavaUI")
    products = {product["name"] for product in ui["products"]}
    assert "GuavaUI" in products
    assert not products.intersection({"GuavaUIDemo", "PetDemo", "GalleryContent", "CounterExample", "GuavaUIApp"})
    target = next(target for target in ui["targets"] if target["name"] == "GuavaUI")
    dependencies = {item["byName"][0] for item in target["dependencies"] if "byName" in item}
    assert "GuavaUIWorkspace" not in dependencies
    for package in (ui, manifest("GuavaUI/Portable")):
        assert not any("examples" in str(path).lower() for path in local_dependencies(package))
    workspace = manifest(".")
    assert local_dependencies(workspace) == {ROOT / "Editor"}
    assert len(workspace["targets"]) == 1, "The workspace must not duplicate Editor's target graph"
    android = manifest("Platforms/Android", GUAVA_ANDROID_UI_PACKAGE=str(ROOT / "examples/GuavaUIStarter"))
    assert not local_dependencies(android).intersection({ROOT / "Editor", ROOT / "GuavaUI/Examples", ROOT / "examples/Counter"})
    with tempfile.TemporaryDirectory(prefix="guava-game-contract-") as directory:
        game = manifest("Platforms/Android", GUAVA_ANDROID_GAME_PACKAGE=directory)
        assert ROOT / "Editor" in local_dependencies(game)
        assert ROOT / "GuavaUI/Examples" not in local_dependencies(game)
    showcase = manifest("Platforms/Android")
    assert ROOT / "GuavaUI/Examples" in local_dependencies(showcase)
    assert ROOT / "Editor" not in local_dependencies(showcase)
    for base in (ROOT / "examples/GuavaUIStarter/Sources", ROOT / "Tools/Guava/Sources/GuavaCLI/Templates/UI/Sources"):
        content = (base / "AppContent/App.swift").read_text()
        assert "import GuavaUI\n" in content
        assert "import NativeRHI" not in content and "import GuavaUIRuntime" not in content
        assert "makeApplicationContent()" in content
    template = ROOT / "Tools/Guava/Sources/GuavaCLI/Templates/UI"
    example = ROOT / "examples/GuavaUIStarter"
    for source in template.rglob("*"):
        if not source.is_file():
            continue
        relative = source.relative_to(template)
        destination = example / (str(relative)[:-3] if str(relative).endswith(".in") else relative)
        expected = source.read_text()
        assert destination.read_text() == expected, f"Starter drifted from its template: {relative}"
    tools = manifest("Tools/Guava")
    assert {item["name"] for item in tools["products"]} == {"guava"}
    assert local_dependencies(tools) == {ROOT / "Platforms/Android/Contract"}
    assert not (ROOT / "Platforms/Android/Tools").exists(), "Android must not own a separate developer CLI"
    assert not (example / "android.swift").exists()
    assert not (example / "guava-android.json").exists()
    configuration = json.loads((example / "guava.json").read_text())
    assert set(configuration["targets"]["platforms"]) == {"mac", "win", "linux", "android"}
    assert (example / configuration["toolchain"]["enginePath"]).resolve() == ROOT
    starter = manifest("examples/GuavaUIStarter")
    resources = (example / "Sources/AppContent/AppResources.swift").read_text()
    assert f'{starter["name"]}_AppContent' in resources, "Resource lookup must match the actual SwiftPM package and target"
    print("Module boundaries passed: production UI, workspace launcher, Android application/game/showcase, and application templates")


if __name__ == "__main__":
    check()
