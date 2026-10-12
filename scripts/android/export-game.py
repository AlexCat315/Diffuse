#!/usr/bin/env python3
"""Export a Guava project as an arm64 Android APK with statically compiled Swift gameplay."""
import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
from pathlib import Path
from common import ROOT, OUTPUT, run, sdk_root, ndk_root, build

SPEC = importlib.util.spec_from_file_location('android_apk', Path(__file__).with_name('build-app.py'))
APK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(APK)


def gameplay_package(project, destination):
    """Each script owns a module so projects may contain multiple GameScript types."""
    if destination.exists(): shutil.rmtree(destination)
    destination.mkdir(parents=True)
    index = project / '.guava/static-scripts.json'
    entries = json.loads(index.read_text())['entries'] if index.is_file() else []
    targets, imports, registrations = [], [], []
    products = ['EngineKernel', 'SceneRuntime', 'ScriptRuntime', 'SIMDCompat']
    dependencies = ', '.join(f'.product(name: "{name}", package: "Engine")' for name in products)
    for number, entry in enumerate(entries):
        module = f'ProjectScript{number}'
        source = destination / 'Sources' / module
        source.mkdir(parents=True)
        shutil.copyfile(project / entry['source'], source / 'GameScript.swift')
        identifier = json.dumps(entry['identifier'])
        (source / 'Registration.swift').write_text(
            'import ScriptRuntime\npublic func registerProjectScript(into runtime: ScriptRuntime) {\n'
            f'    runtime.register(behavior: GameScript.self, named: {identifier})\n}}\n')
        targets.append(f'.target(name: "{module}", dependencies: [{dependencies}])')
        imports.append(f'import {module}')
        registrations.append(f'        {module}.registerProjectScript(into: runtime)')
    source = destination / 'Sources/GuavaAndroidGameplay'
    source.mkdir(parents=True)
    (source / 'Registry.swift').write_text('import ScriptRuntime\n' + '\n'.join(imports) +
        '\npublic enum ProjectGameplay {\n    public static func register(into runtime: ScriptRuntime) -> Int {\n' +
        '\n'.join(registrations) + f'\n        return {len(entries)}\n    }}\n}}\n')
    aggregate_dependencies = ['.product(name: "ScriptRuntime", package: "Engine")'] + [f'"ProjectScript{i}"' for i in range(len(entries))]
    targets.append('.target(name: "GuavaAndroidGameplay", dependencies: [' + ', '.join(aggregate_dependencies) + '])')
    (destination / 'Package.swift').write_text('// swift-tools-version: 6.4\nimport PackageDescription\n'
        'let package = Package(name: "GuavaAndroidGameplay", products: [.library(name: "GuavaAndroidGameplay", targets: ["GuavaAndroidGameplay"])],\n'
        f'    dependencies: [.package(path: {json.dumps(str(ROOT / "Engine"), ensure_ascii=False)})],\n'
        '    targets: [' + ',\n        '.join(targets) + '])\n')
    return len(entries)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--application-id', required=True)
    parser.add_argument('--name')
    parser.add_argument('--android-sdk')
    parser.add_argument('--ndk')
    parser.add_argument('--install', action='store_true')
    parser.add_argument('--serial')
    parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
    parser.add_argument('--keystore', type=Path)
    parser.add_argument('--key-alias')
    parser.add_argument('--store-password-env', default='GUAVA_ANDROID_STORE_PASSWORD')
    parser.add_argument('--key-password-env', default='GUAVA_ANDROID_KEY_PASSWORD')
    args = parser.parse_args()
    if not re.fullmatch(r'[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+', args.application_id):
        parser.error('--application-id must be a lowercase reverse-domain Android ID')
    if args.output.suffix.lower() != '.apk': parser.error('--output must name an .apk file')
    project = args.project.resolve()
    signing = None
    if args.keystore:
        if not args.key_alias or not args.keystore.is_file(): parser.error('Supply a keystore file and --key-alias')
        for variable in (args.store_password_env, args.key_password_env):
            if variable not in os.environ: parser.error(f'Set the password environment variable {variable}')
        signing = {'keystore': str(args.keystore.resolve()), 'alias': args.key_alias,
                   'store_password_env': args.store_password_env, 'key_password_env': args.key_password_env}
    name = args.name or project.name
    sdk, ndk = sdk_root(args.android_sdk), ndk_root(args.ndk)
    directory = OUTPUT / ('export-' + args.application_id)
    directory.mkdir(parents=True, exist_ok=True)
    staged = directory / 'Project'
    swift = os.environ.get('GUAVA_SWIFT_EXECUTABLE', shutil.which('swift'))
    run([swift, 'build', '--package-path', ROOT / 'Editor', '--product', 'GuavaProjectExport'])
    binaries = Path(subprocess.check_output([swift, 'build', '--package-path', str(ROOT / 'Editor'), '--show-bin-path'], text=True).strip())
    run([binaries / 'GuavaProjectExport', '--project', project, '--output', staged, '--static-scripts', '--name', name])
    package = directory / 'GuavaAndroidGameplay'
    count = gameplay_package(staged, package)
    os.environ['GUAVA_ANDROID_GAME_PACKAGE'] = str(package)
    products = build('GuavaAndroidApp', ndk, args.configuration)
    apk = APK.package_apk(products, sdk, ndk, launch={'mode': 'game', 'component': 'introduction', 'project': 'GuavaProject'},
        application_id=args.application_id, name=name, output=args.output, project=staged,
        signing=signing, debuggable=args.configuration == 'debug')
    report = {'applicationID': args.application_id, 'name': name, 'scripts': count, 'apk': str(apk),
              'target': 'aarch64-unknown-linux-android28', 'swift': '6.4.0', 'configuration': args.configuration,
              'signing': 'custom' if signing else 'development', 'scene': json.loads((staged / 'build.json').read_text())}
    apk.with_suffix('.json').write_text(json.dumps(report, indent=2) + '\n')
    if args.install: APK.install(apk, sdk, args.serial, args.application_id)


if __name__ == '__main__': main()
