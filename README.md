[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

# Diffuse

An **AI agent driven workstation** written in Swift, bringing text/code editing, game development, animation and video editing into a shared workspace.

Cove's core thesis: **creative intent, world state, runtime execution, and AI understanding are not four layers — they are four views of the same thing.** Humans and AI authors share the exact same world-mutation primitives; every interaction is a training signal by default; and the world is a continuously maintained semantic graph, not a serialized snapshot.

- 🇨🇳 **中文版**: [README.zh.md](README.zh.md)

---

## Overview

| Layer | Technology |
|-------|-----------|
| Primary language | Swift 6.4.1 |
| Render backend | NativeRHI (Metal / Vulkan / DX12) |
| UI layout | Yoga (Meta) |
| Text shaping / rendering | HarfBuzz + FreeType |
| Physics | Natsel (Swift) |
| Platform shell | SDL3 / native |
| Target platform (first) | macOS 26+; Linux & Windows in progress |

Studio contains the Engine and Editor packages plus an MCP server; the SDK is an independent repository:

- **`Engine/`** — rendering, scene, simulation, asset pipeline, AI runtime kernels, observation bus, film pipeline (EXR / color / denoise / render farm).
- **`CoveUI/`** — the [CoveUI SDK](https://github.com/AlexCat315/Cove) is installed globally at the version pinned by `Editor/cove.json`; projects share its framework sources, native libraries and CLI. CI uses this path as a link to the shared SDK.
- **`Editor/`** — the desktop editor application. Hosts the engine, mounts CoveUI panels (Hierarchy / Inspector / Console / Asset Browser / Viewport / Sequencer / Farm Dashboard …), and is the primary surface for AI interactions.
- **`DiffuseMCP/`** — an [MCP](https://modelcontextprotocol.io/) server that exposes Diffuse editor capabilities to LLM agents over stdio / WebSocket.

CI installs the SDK release pinned by `Editor/cove.json`. For local development before that SDK version is released, set `COVE_SDK_ROOT` to the matching SDK checkout.

---

## Architecture at a Glance

```
Editor (top-level app)
 ├─ EditorCore (state machine, panel registry, transaction host, AI UI)
 │  ├───► Engine (SceneRuntime, AssetPipeline, ObservationBus, CapabilityGraph)
 │  └───► CoveUI (Compose API + NativeRHI renderer, shared NativeRHI Device with Engine)
 │
 CoveUI SDK
 ├── UI framework / platform hosts / CLI
 └── NativeRHI / PlatformShell / logging / platform values

 Engine (core)
 ├── RenderBackend / SceneRuntime / ScriptRuntime
 ├───► CoveUI SDK's NativeRHI and platform services
 ├── AIRuntime (Session, WorldView, Signal, Proposal, Edit)
 ├── ObservationBus (event bus, cross-process bridge at M11)
 └── (film) SequenceRuntime, CinematicRenderer, ColorPipeline, ImageIO, RenderFarm
```

### Core AI concepts

- **World** — the single source of truth. Entities carry three property layers: `authored` (human-set, permanent), `evaluated` (engine-derived, e.g. world-space position), and `inferred` (AI-inferred, confidence-tagged). Relationships are first-class directed edges.
- **Session** — an AI's continuous presence in a project (persists across editor restarts). Maintains a `WorldView` incrementally updated from `WorldEvent`s.
- **Signal** — the unified input representation. Covers natural language, direct manipulation, reference images, code diffs, selection changes, and `UserCorrection` (the most valuable signal: AI proposed X, user edited to Y).
- **Proposal** — any author's intent-to-change. Always validated, optionally staged for ghost-world preview, optionally requires user confirmation.
- **Edit** — a change already applied to the World. Every Edit is a training datum by default; there is no separate "intent training logger."

Full design (in Chinese): [`docs/architecture.md`](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/architecture.md).

### Roadmap

- **M0 – foundation** ✅ three packages build cleanly with `swift build`.
- **M1 – first 3D frame + UI data layer** ✅ first real GPU scene; NodeTree + Recomposer.
- **M2 – visible UI frame** ✅ CoveUI window renders real rectangles + text.
- **M3 – editor UI takes shape** ✅ Hierarchy / Inspector / Console; theme & default styles system complete.
- **M4 – full editing workflow** ✅ asset browser + viewport + gizmo; multi-threaded rendering.
- **M5 – in-game UI + asset pipeline** ✅ GLTF import; `InGameUIProviding` protocol injection.
- **M6 – cross-platform + packaging** ongoing — Windows / Linux compile; standalone `.app` output.
- **M7 – AI skeleton + film foundation** ongoing — `ObservationBus`, `CapabilityRuntime`, `IntentIR`/`TransactionIR`, `MinimalConfirmationUI`; `SequenceRuntime`, `CinematicRenderer`, EXR I/O, OCIO/ACES baseline.
- **M8 – film rendering depth** multi-bounce path tracing, denoise (OIDN), Cryptomatte, deep EXR, lookdev.
- **M9 – semantic pipeline** StructureExtractor → GeometryFingerprinter → SemanticAnalyzer → SemanticMemoryStore; first capability verbs registered.
- **M10 – scene-from-image + first end-to-end workflows** reference image → SceneDocument; LLM agent bridge; film dailies & game playtest loops.
- **M11 – render farm + long-session memory** cross-process ObservationBus bridge; farm orchestrator; cross-session WorldView reconciliation.

Full roadmap with per-milestone acceptance criteria (in Chinese): [`docs/roadmap.md`](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/roadmap.md).

---

## Building

### Prerequisites

- Swift 6.4.1 (official Swift toolchain)
- CMake 4.4.4
- A C/C++ toolchain:
  - **macOS**: Xcode Command Line Tools
  - **Linux**: GCC or Clang
  - **Windows**: Visual Studio 2026 (C++ workload)
- Git
- Graphics: system Metal on macOS; DX12 by default on Windows, with the Windows SDK and DXC for shader compilation; Vulkan on Linux and as a Windows alternative. Vulkan headers are pinned in the SDK and the runtime loads the system graphics driver.

### First build

```bash
git clone https://github.com/AlexCat315/Diffuse.git
cd Diffuse
git submodule update --init --recursive
./cove studio native-bootstrap
./cove build Editor
```

`./cove` uses the shared Cove SDK declared by `Editor/cove.json`, or `COVE_SDK_ROOT` for a local development checkout. `cove studio native-bootstrap` installs the SDK’s released native artifacts, builds Studio’s FFmpeg and OpenEXR/Imath dependencies, and stages the pinned Wasmtime runtime. It is cross-platform and initializes the MSVC toolchain on Windows.

After the first bootstrap, day-to-day development only needs:

```bash
./cove build Editor
```

> **Force rebuild of native deps:** `./cove studio native-bootstrap --force`

### Individual packages

```bash
./cove internal build-package Engine   # engine + renderers
./cove build Editor   # editor (run: ./cove run Editor)
./cove internal build-package DiffuseMCP --product DiffuseMCP # MCP server
```

The SDK's portable core, DevTools server, browser prototype and examples live in the [CoveUI repository](https://github.com/AlexCat315/Cove).

---

## Vendored Dependencies

| Library | Form | Source |
|---------|------|--------|
| Yoga | SwiftPM source build | SwiftPM `facebook/yoga` 3.2.1 |
| FreeType | CMake source build → `.artifactbundle` | SDK checkout `third-party/freetype` |
| HarfBuzz | CMake source build → `.artifactbundle` | SDK checkout `third-party/harfbuzz` |
| SDL3 | SDK release artifact / CMake source build | SDK checkout `Runtime/third-party/sdl3` |
| Imath | CMake source build | submodule under `Engine/third-party/imath` |
| OpenEXR | CMake source build | submodule under `Engine/third-party/openexr` |
| Natsel | Swift Package Manager | `AlexCat315/Natsel` main; commit recorded in lockfiles |
| Wasmtime | pinned official C API dynamic library → `.xcframework` | Bytecode Alliance release (SHA-256 verified, macOS) |

The pattern is uniform: each SPM package owns its native deps under `<package>/third-party/`, CMake builds them into `<package>/vendor/` (gitignored), and the package consumes them via `.binaryTarget(path:)`.

---

## Project Structure

```
Diffuse/
├── Engine/Sources/
│   ├── AIRuntime/            (Session, WorldView, Signal, Proposal, RetryPolicy)
│   ├── AssetPipeline/        (asset import, registry, loader)
│   ├── CapabilityRuntime/    (CapabilityRegistry, PreconditionChecker, EffectAnalyzer)
│   ├── CinematicRenderer/    (PathTracer, BSDF, SamplingStrategy, AOV)
│   ├── ColorPipeline/        (OCIO bridge, ACES config, view/display transform)
│   ├── EngineCore/           (core types, LatestValueBuffer, EngineFFI)
│   ├── EngineKernel/         (boot → input → simulation → render submit tick loop)
│   ├── ContextMemory/        (cross-session symbolic memory, reducers)
│   ├── DenoiseBridge/        (OIDN / OptiX bridges)
│   ├── ImageIO/              (EXRReader, EXRWriter, DeepEXRWriter, Cryptomatte)
│   ├── IntentRuntime/        (Edit, IntentIR, TransactionIR, TransactionExecutor, AmbiguityScorer)
│   ├── ObservationBus/       (Publisher/Subscriber, Bus bridge)
│   ├── RenderBackend/        (render packet, multi-threaded renderer scheduling)
│   ├── RenderFarm/           (orchestrator, worker, job scheduler, result collector)
│   ├── SceneRuntime/         (ECS, entities, components, audio, physics, prefabs, schedules)
│   ├── SceneFromImage/       (reference image → layout inference → scene draft)
│   ├── ScriptRuntime/        (script context, component, lifecycle, input, drawUI)
│   ├── SemanticPipeline/     (structure extraction, fingerprinting, analysis, memory)
│   ├── SequenceRuntime/      (SequenceDocument, ShotEvaluator, ClipScheduler)
│   └── SIMDCompat/           (cross-platform SIMD helpers)
├── CoveUI/                   (external SDK checkout, ignored; src/ at the CoveUI repository)
├── Platforms/Android/         (JNI/Java surface host, APK tools, launch contract)
├── Editor/Sources/
│   ├── EditorApp/             (thin executable launcher)
│   ├── EditorUI/              (editor windows and panels)
│   ├── EditorCore/            (editor project/application domain)
│   └── GameRuntime/           (project simulation and player services)
├── examples/                  (CrystalRush game content)
├── DiffuseMCP/Sources/DiffuseMCP/  (MCP server exposing Diffuse editor capabilities)
└── .github/workflows/        (CI matrices for engine / editor / MCP + release)
```

The website and documentation portal live in the independent [GuavaWebsite repository](https://github.com/AlexCat315/GuavaWebsite).

---

## Continuous Integration

GitHub Actions workflows live under `.github/workflows/`:

- `ci-engine.yml` — Engine package matrix.
- `ci-editor.yml` — Editor package.
- `ci-diffuse-mcp.yml` — MCP server package.
- `release.yml` — release builds.

The SDK's own CI lives in the [CoveUI repository](https://github.com/AlexCat315/Cove).

---

## Documentation

- **Website and documentation:** [GuavaWebsite](https://github.com/AlexCat315/GuavaWebsite)
- **Architecture (AI-Native design, in Chinese):** [`docs/architecture.md`](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/architecture.md)
- **Full roadmap & milestones (in Chinese):** [`docs/roadmap.md`](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/roadmap.md)
- **Project overview (in Chinese):** [`docs/project-overview.md`](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/project-overview.md)
- **UI design system (in Chinese):** [`docs/components/`](https://github.com/AlexCat315/GuavaWebsite/tree/main/docs/components)
- **MCP tools (AI tools API):** [`docs/api/ai-tools.md`](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/api/ai-tools.md)

---

## License

Diffuse is open source under the [Apache License 2.0](LICENSE). Third-party dependencies retain their upstream licenses; see [NOTICE](NOTICE) for attribution.


The product is Diffuse. Runtime modules under `Engine/` remain reusable building blocks. The Editor adds independent text/code documents and a video timeline with cuts, ordering, frame preview, playback, and MP4 export. See [workstation boundaries](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/architecture/workstation.md), [media](Engine/Media/README.md), and [component standards](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/components/standard.md).

New CLI applications include an iOS/iPadOS Xcode host alongside desktop and Android. `cove build MyApp --ios` builds for Simulator; `cove run MyApp --ios --simulator UDID` installs and launches. Devices require `--device ID --team TEAM_ID`. Native Metal/SDL and Wasmtime/Pulley artifacts are staged separately from desktop dependencies.
