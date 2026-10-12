"""Build the repository's pinned FreeType/HarfBuzz sources for Android ARM64."""
import json
import os
import shutil
from common import ROOT, OUTPUT, TRIPLE, run


def prepare(ndk):
    directory = OUTPUT / 'fonts'
    install = directory / 'install'
    vendor = directory / 'vendor'
    sources = ROOT / 'GuavaUI/third-party'
    common = ['-G', 'Ninja', f'-DCMAKE_TOOLCHAIN_FILE={ndk}/build/cmake/android.toolchain.cmake',
              '-DANDROID_ABI=arm64-v8a', '-DANDROID_PLATFORM=android-28',
              '-DANDROID_STL=c++_shared', '-DCMAKE_BUILD_TYPE=Release',
              '-DBUILD_SHARED_LIBS=OFF', '-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
              f'-DCMAKE_INSTALL_PREFIX={install}']
    for name, options in [
        ('freetype', [f'-DFT_DISABLE_{feature}=ON' for feature in ('ZLIB', 'BZIP2', 'PNG', 'HARFBUZZ', 'BROTLI')]),
        ('harfbuzz', [f'-DCMAKE_PREFIX_PATH={install}', '-DHB_HAVE_FREETYPE=ON',
                      f'-DFREETYPE_LIBRARY={install}/lib/libfreetype.a',
                      f'-DFREETYPE_INCLUDE_DIR_ft2build={install}/include/freetype2',
                      f'-DFREETYPE_INCLUDE_DIR_freetype2={install}/include/freetype2',
                      '-DHB_BUILD_SUBSET=OFF', '-DHB_BUILD_UTILS=OFF', '-DHB_BUILD_TESTS=OFF',
                      '-DHB_HAVE_GLIB=OFF', '-DHB_HAVE_ICU=OFF', '-DHB_HAVE_GRAPHITE2=OFF', '-DHB_HAVE_CORETEXT=OFF']),
    ]:
        if not (sources / name / 'CMakeLists.txt').is_file():
            raise ValueError(f'Initialize the GuavaUI/third-party/{name} submodule')
        run(['cmake', '-S', sources / name, '-B', directory / name, *common, *options])
        run(['cmake', '--build', directory / name, '--parallel', os.environ.get('CMAKE_BUILD_PARALLEL_LEVEL', '4')])
        run(['cmake', '--install', directory / name])
    for module, library, headers in [('CFreeType', 'freetype', 'freetype2'), ('CHarfBuzz', 'harfbuzz', 'harfbuzz')]:
        bundle = vendor / f'{module}.artifactbundle'
        variant = bundle / 'android-arm64'
        (variant / 'lib').mkdir(parents=True, exist_ok=True)
        shutil.copytree(install / 'include' / headers, variant / 'include', dirs_exist_ok=True)
        shutil.copy2(install / 'lib' / f'lib{library}.a', variant / 'lib')
        for source, target in [(f'{module}.h', f'{module}.h'), (f'{module}.modulemap', 'module.modulemap')]:
            shutil.copy2(sources / 'cmake/templates' / source, variant / 'include' / target)
        version = json.loads((ROOT / f'GuavaUI/vendor/{module}.artifactbundle/info.json').read_text())['artifacts'][module]['version']
        (bundle / 'info.json').write_text(json.dumps({'schemaVersion': '1.0', 'artifacts': {module: {
            'type': 'staticLibrary', 'version': version, 'variants': [{
                'path': f'android-arm64/lib/lib{library}.a', 'supportedTriples': [TRIPLE, 'aarch64-unknown-linux-android'],
                'staticLibraryMetadata': {'headerPaths': ['android-arm64/include']},
            }],
        }}}, indent=2) + '\n')
    return vendor
