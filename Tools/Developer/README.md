# GuavaDeveloper (`guava-dev`)

First-party Swift replacement for the former `scripts/` directory. Every
repository task — native bootstrap, media and plugin staging, shader toolchain,
GPU regression reporting, module-boundary and maintainability checks, and the
MCP/editor/browser/Android validation harnesses — lives here as a Swift target.

First-party repository tooling requires no Python interpreter or Python
packages. Vendored third-party source trees retain their upstream files.

## Running

```sh
swift run --package-path Tools/Developer guava-dev <command> [options]
```

The executable discovers the checkout by walking up from its current directory,
or from `GUAVA_ROOT` when set. SwiftPM's `--package-path` is still relative to the
shell's working directory: from `GuavaUI/Browser`, use `../../Tools/Developer`
or the existing `npm run` commands.

The shipped `guava` CLI (`Tools/Guava`) shells out to `guava-dev` for the tasks
it shares with CI; it does not depend on this package as a library, so the
dependency direction stays one-way.

## Commands

| Command | Purpose |
| --- | --- |
| `maintainability [--report]` | Reject new oversized Swift declarations |
| `boundaries` | Validate package/product/app boundaries |
| `shader compile\|rebuild\|bootstrap-slang` | Compile Slang artifacts and stage `slangc` |
| `vulkan bootstrap` | Build pinned Vulkan headers/loader |
| `media [--platform N] [--check]` | Build pinned LGPL FFmpeg |
| `plugins stage\|prepare\|verify` | Stage Wasmtime and run the portable probe |
| `native-bootstrap [--force]` | Build Engine + GuavaUI native dependencies |
| `ios-native [--sdk S] [--arch A]` | Stage isolated iOS native dependencies |
| `ios-simulator udid\|validate` | Pick a simulator and verify a built `.app` renders |
| `validate <operation>` | MCP protocol, editor loop, DevTools and session checks |
| `android <operation>` | Android device validation harnesses |
| `browser <operation>` | Headless Chromium checks over CDP |
| `gpu-regression run\|verify DIR` | Run and verify the GPU regression inventory |

Run `guava-dev --help`, or `guava-dev <command> --help`, for the full flag list.

## Ownership and dependencies

```text
Sources/
  GuavaDev/                  command dispatch and help
  Infrastructure/
    ToolSupport/             processes, files, archives, downloads and digests
    ImageCodec/              Swift screenshot decoding boundary
    CImageDecoder/           thin adapter to the engine's vendored stb header
  Build/
    NativeBootstrap/         native dependency orchestration
    MediaStaging/            FFmpeg recipes and provenance
    PluginStaging/           Wasmtime staging and portable probe
    ShaderToolchain/         Slang compilation and artifact contracts
    VulkanBootstrap/         Vulkan SDK staging
    IOSStaging/              isolated iOS native builds
  Checks/
    Maintainability/         structural limits and frozen debt
    Boundaries/              package boundaries and template parity
  Validation/
    Runtime/                 MCP, editor loop and DevTools
    Android/                 device probes, input and screenshots
    Browser/                 Chromium protocol, HTTP server and browser gates
    GPU/                     GPU regression inventory and reports
    IOS/                     simulator selection and frame verification
Tests/<Target>Tests/          tests owned by each target
```

The package publishes only the `guava-dev` executable. Cross-target entry points
and shared values use Swift `package` access; implementation details stay
`internal` or `private`. Imports declare their access explicitly, and generated
resource accessors use `InternalImportsByDefault`.

Build recipes depend on infrastructure or another recipe they orchestrate.
Validation harnesses depend on infrastructure; they launch built applications
at the process boundary. There are no package dependencies on Engine, Editor,
or GuavaUI, so tooling can build before native artifacts exist. Screenshot
decoding includes the existing stb header directly, without linking Engine.
The `boundaries` command guards this separation; `maintainability` also scans
this package's first-party Swift sources.

Add an operation to its owning domain, rather than creating a target for each
former script. Put reusable process IO and deadlines in `ToolSupport`; keep
domain-specific protocol and artifact formats with their owner. Application
behavior belongs in the application package's tests. Keep `GuavaDev` limited
to argument dispatch, and update CI, documentation and templates together.

## Host support

Build recipes, quality checks and GPU report verification compile on macOS,
Linux and Windows. iOS staging and simulator execution require macOS. POSIX
browser/device/runtime harnesses are built on macOS and Linux; Windows command
dispatch reports their host requirement without compiling unsupported APIs.
DevTools capture and session operations currently require macOS.

Browser checks need an installed Chromium/Chrome; set `GUAVA_CHROMIUM` to an
explicit executable if discovery does not find it. Browser CI installs Chrome
directly instead of depending on a Python browser installation.
Each verification page owns an isolated browser context, including storage and
download policy, so one scale/backend check cannot carry state into the next.

## Tests

```sh
swift test --package-path Tools/Developer

# Include real Chromium protocol and screenshot checks.
GUAVA_TEST_CHROMIUM=1 swift test --package-path Tools/Developer

# Include compilation tests against the pinned Slang compiler.
SLANGC="$PWD/Engine/vendor/slang/bin/slangc" swift test --package-path Tools/Developer
```

`ci-developer-tools.yml` builds and tests the standalone package on all three
hosts, exercises a real browser on POSIX hosts, and checks safe help entry
points. Device, GPU, Wasm rebuild and full editor gates remain in their domain
workflows and require their normal hardware/toolchains.
