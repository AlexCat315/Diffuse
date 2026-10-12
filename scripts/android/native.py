"""Build the shared engine's Android native dependencies without replacing host archives."""
import os
from common import ROOT, OUTPUT, run


def prepare(ndk):
    directory = OUTPUT / 'native'
    vendor = directory / 'vendor'
    run(['cmake', '-S', ROOT / 'Engine/third-party', '-B', directory, '-G', 'Ninja',
         f'-DCMAKE_TOOLCHAIN_FILE={ndk}/build/cmake/android.toolchain.cmake',
         '-DANDROID_ABI=arm64-v8a', '-DANDROID_PLATFORM=android-28', '-DANDROID_STL=c++_shared',
         '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
         '-DGUAVA_BUILD_OPENEXR=OFF', f'-DGUAVA_VENDOR_DIR={vendor}',
         f'-DCMAKE_INSTALL_PREFIX={directory / "install"}'])
    run(['cmake', '--build', directory, '--target', 'stage_sdl3', 'stage_jolt', 'stage_image_decode',
         '--parallel', os.environ.get('CMAKE_BUILD_PARALLEL_LEVEL', '4')])
    run(['cmake', '--install', directory])
    return vendor
