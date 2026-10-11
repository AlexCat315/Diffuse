#!/usr/bin/env python3
"""Verify the current run's Swift Testing XML and completed XCTest results."""
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

ENGINE_SUITES = {
    'RenderBackendGPUSmokeTests', 'ShaderCatalogTests', 'RenderThreadTests',
    'NativeOpaqueTests', 'NativePBRTests', 'NativePostTests', 'NativeAnimatedMeshTests',
    'NativeStylizedTests', 'NativeParticleTests', 'NativeParticleSimulationTests',
    'NativeParticleInstanceTests', 'NativeViewportSurfaceTests', 'NativeEditorGridTests',
}
UI_SUITES = {
    'NativeAppWindowTests', 'NativeInGameUIIntegrationTests', 'NativeInGameUILifecycleTests',
    'NativeViewportIntegrationTests', 'NativeDrawListParityTests', 'NativeImageAssetTests',
    'NativeUIBindingReuseTests',
}


def xctest_cases(log):
    # SwiftBuild 6.4 does not emit XCTest XML. Parse only completed test-case
    # records, never starts or suite summaries; an unrun case cannot satisfy CI.
    pattern = r"^Test Case '(.+)' (passed|failed|skipped) \(([0-9.]+) seconds\)\.\s*$"
    cases = []
    for identity, status, elapsed in re.findall(pattern, log, re.MULTILINE):
        if identity.startswith('-[') and identity.endswith(']'):
            classname, name = identity[2:-1].rsplit(' ', 1)
        else:
            classname, name = identity.rsplit('.', 1)
        case = ET.Element('testcase', classname=classname, name=name, time=elapsed)
        if status != 'passed':
            ET.SubElement(case, 'skipped' if status == 'skipped' else 'failure')
        cases.append(case)
    return cases


def load_cases(directory, prefix):
    # SwiftPM appends -swift-testing to its Swift Testing report. The caller
    # creates a fresh directory, so previous runs cannot satisfy the inventory.
    reports = list(directory.glob(f'{prefix}-results*.xml'))
    if not reports:
        raise ValueError(f'{prefix} regression did not produce an xUnit report')
    cases = [case for path in reports for case in ET.parse(path).getroot().iter('testcase')]
    completed = xctest_cases((directory / f'{prefix}.log').read_text())
    suite = ET.Element('testsuite', name='XCTest', tests=str(len(completed)))
    suite.extend(completed)
    ET.ElementTree(suite).write(directory / f'{prefix}-xctest.xml', encoding='utf-8', xml_declaration=True)
    # Some SwiftPM versions already include XCTest in the requested XML.
    reported = {(case.get('classname'), case.get('name')) for case in cases}
    return cases + [case for case in completed
                    if (case.get('classname'), case.get('name')) not in reported or len(case)]


def verify_cases(cases, suites, methods):
    if any(case.find(status) is not None for case in cases for status in ('skipped', 'failure', 'error')):
        raise ValueError('GPU regression contains skipped or failed tests')
    executed_suites = {case.get('classname', '').rsplit('.', 1)[-1] for case in cases}
    executed_methods = {case.get('name', '').split('(')[0] for case in cases}
    missing = (suites - executed_suites) | (methods - executed_methods)
    if missing:
        raise ValueError(f'GPU regression inventory is incomplete: {sorted(missing)}')


def main():
    directory = Path(sys.argv[1])
    engine = load_cases(directory, 'gpu')
    ui = load_cases(directory, 'ui')
    verify_cases(engine, ENGINE_SUITES, {'productionScenes', 'editorGrid'})
    verify_cases(ui, UI_SUITES, {'testWindowTargetsResizeSuspendAndCloseIndependently', 'recordingConstantsAreIndependent'})
    print(f'GPU regression verified: {len(engine)} Engine and {len(ui)} GuavaUI test functions executed')


if __name__ == '__main__':
    try:
        main()
    except ValueError as error:
        raise SystemExit(str(error)) from error
