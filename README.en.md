[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

# Guava Engine

An **AI-Native 3D game & film engine** written in Swift, built around a unified semantic world rather than a traditional translation-layer API.

Guava's core thesis: **creative intent, world state, runtime execution, and AI understanding are not four layers — they are four views of the same thing.** Humans and AI authors share the exact same world-mutation primitives; every interaction is a training signal by default; and the world is a continuously maintained semantic graph, not a serialized snapshot.

- 🇨🇳 **中文版**: [README.md](README.md)
- 📖 **Architecture design doc** (in Chinese): [`docs/architecture.md`](docs/architecture.md)
- 🗺 **Roadmap** (in Chinese): [`docs/roadmap.md`](docs/roadmap.md)

---

## Overview

| Layer | Technology |
|-------|-----------|
| Primary language | Swift 6.1+ |
| Render backend | WebGPU (wgpu-native) |
| UI layout | Yoga (Meta) |
| Text shaping / rendering | HarfBuzz + FreeType |
| Physics | Jolt Physics |
| Platform shell | SDL3 / native |
| Target platform (first) | macOS 14+ (Sonoma); Linux & Windows in progress |

The repository ships three top-level SwiftPM packages plus an MCP server:

- **`Engine/`** — rendering, scene, simulation, asset pipeline, AI runtime kernels, observation bus, film pipeline (EXR / color / denoise / render farm).
- **`GuavaUI/`** — a declarative, SwiftUI-style UI framework with a wgpu renderer. Also the foundation of the in-game UI, injected into the engine via a protocol (no circular dependency).
- **`Editor/`** — the desktop editor application. Hosts the engine, mounts GuavaUI panels (Hierarchy / Inspector / Console / Asset Browser / Viewport / Sequencer / Farm Dashboard …), and is the primary surface for AI interactions.
- **`guava-mcp/`** — an [MCP](https://modelcontextprotocol.io/) server that exposes Guava capabilities to LLM agents over stdio / WebSocket.

---

## Architecture at a Glance

```
Editor (top-level app)
 ├─ EditorCore (state machine, panel registry, transaction host, AI UI)
 │  ├───► Engine (SceneRuntime, AssetPipeline, ObservationBus, CapabilityGraph)
 │  └───► GuavaUI (Compose API + wgpu renderer, shared WGPUDevice with Engine)
 │
 GuavaUI (UI framework)
 └───► Engine.RHIWGPU (device & surface only; no hard dependency on 3D rendering)

 Engine (core)
 ├── RHIWGPU / RenderBackend / SceneRuntime / ScriptRuntime
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

Full design (in Chinese): [`docs/architecture.md`](docs/architecture.md).

### Roadmap

- **M0 – foundation** ✅ three packages build cleanly with `swift build`.
- **M1 – first 3D frame + UI data layer** ✅ first real wgpu scene; NodeTree + Recomposer.
- **M2 – visible UI frame** ✅ GuavaUI window renders real rectangles + text.
- **M3 – editor UI takes shape** ✅ Hierarchy / Inspector / Console; theme & default styles system complete.
- **M4 – full editing workflow** ✅ asset browser + viewport + gizmo; multi-threaded rendering.
- **M5 – in-game UI + asset pipeline** ✅ GLTF import; `InGameUIProviding` protocol injection.
- **M6 – cross-platform + packaging** ongoing — Windows / Linux compile; standalone `.app` output.
- **M7 – AI skeleton + film foundation** ongoing — `ObservationBus`, `CapabilityRuntime`, `IntentIR`/`TransactionIR`, `MinimalConfirmationUI`; `SequenceRuntime`, `CinematicRenderer`, EXR I/O, OCIO/ACES baseline.
- **M8 – film rendering depth** multi-bounce path tracing, denoise (OIDN), Cryptomatte, deep EXR, lookdev.
- **M9 – semantic pipeline** StructureExtractor → GeometryFingerprinter → SemanticAnalyzer → SemanticMemoryStore; first capability verbs registered.
- **M10 – scene-from-image + first end-to-end workflows** reference image → SceneDocument; LLM agent bridge; film dailies & game playtest loops.
- **M11 – render farm + long-session memory** cross-process ObservationBus bridge; farm orchestrator; cross-session WorldView reconciliation.

Full roadmap with per-milestone acceptance criteria (in Chinese): [`docs/roadmap.md`](docs/roadmap.md).

---

## Building

### Prerequisites

- Swift 6.1+ (official Swift toolchain)
- CMake 3.20+
- A C/C++ toolchain:
  - **macOS**: Xcode Command Line Tools
  - **Linux**: GCC or Clang
  - **Windows**: Visual Studio 2022 (C++ workload)
- Git

### First build

```bash
git clone https://github.com/AlexCat315/Guava-Engine.git
cd Guava-Engine
git submodule update --init --recursive
python bootstrap.py
swift build --package-path Editor
```

`bootstrap.py` compiles the native C/C++ dependencies (Yoga, FreeType, HarfBuzz, SDL3, Jolt, OpenEXR/Imath) for each package into its `vendor/` directory and wraps them for SwiftPM. On macOS it also verifies and stages the pinned official Wasmtime Component C API dynamic artifact. It is cross-platform and initializes the MSVC toolchain on Windows.

After the first bootstrap, day-to-day development only needs:

```bash
swift build --package-path Editor
```

> **Force rebuild of native deps:** `python bootstrap.py --force`

### Run the website locally

The official website and documentation portal live under `website/` and use Vue 3, TypeScript, and Vite:

```bash
cd website
npm install
npm run dev
```

`npm run build` validates content, checks types, runs tests, and generates the static site.

### Individual packages

```bash
swift build --package-path Engine   # engine + renderers
swift build --package-path GuavaUI  # UI framework (demo: swift run GuavaUIDemo)
swift build --package-path Editor   # editor (run: swift run GuavaEditor)
swift build --package-path guava-mcp # MCP server (run: swift run GuavaMCP)
```

---

## Vendored Dependencies

| Library | Form | Source |
|---------|------|--------|
| Yoga | CMake source build → `.artifactbundle` | submodule under `GuavaUI/third-party/yoga` |
| FreeType | CMake source build → `.artifactbundle` | submodule under `GuavaUI/third-party/freetype` |
| HarfBuzz | CMake source build → `.artifactbundle` | submodule under `GuavaUI/third-party/harfbuzz` |
| SDL3 | CMake source build → `.artifactbundle` | submodule under `Engine/third-party/sdl3` |
| Imath | CMake source build | submodule under `Engine/third-party/imath` |
| OpenEXR | CMake source build | submodule under `Engine/third-party/openexr` |
| JoltPhysics | CMake source build → `.artifactbundle` | submodule under `Engine/third-party/jolt` |
| wgpu-native | prebuilt binary downloaded from gfx-rs releases at configure time | no submodule |
| Wasmtime | pinned official C API dynamic library → `.xcframework` | Bytecode Alliance release (SHA-256 verified, macOS) |

The pattern is uniform: each SPM package owns its native deps under `<package>/third-party/`, CMake builds them into `<package>/vendor/` (gitignored), and the package consumes them via `.binaryTarget(path:)`.

---

## Project Structure

```
Guava-Engine/
├── Engine/Sources/
│   ├── AIRuntime/            (Session, WorldView, Signal, Proposal, RetryPolicy)
│   ├── AssetPipeline/        (asset import, registry, loader)
│   ├── CapabilityRuntime/    (CapabilityRegistry, PreconditionChecker, EffectAnalyzer)
│   ├── CinematicRenderer/    (PathTracer, BSDF, SamplingStrategy, AOV)
│   ├── ColorPipeline/        (OCIO bridge, ACES config, view/display transform)
│   ├── EngineCore/           (core types, RingBuffer, EngineFFI)
│   ├── EngineKernel/         (boot → input → simulation → render submit tick loop)
│   ├── ContextMemory/        (cross-session symbolic memory, reducers)
│   ├── DenoiseBridge/        (OIDN / OptiX bridges)
│   ├── ImageIO/              (EXRReader, EXRWriter, DeepEXRWriter, Cryptomatte)
│   ├── IntentRuntime/        (Edit, IntentIR, TransactionIR, TransactionExecutor, AmbiguityScorer)
│   ├── ObservationBus/       (Publisher/Subscriber, Bus bridge)
│   ├── PlatformShell/        (SDL3 + native platform abstraction, Cursor, logging)
│   ├── RenderBackend/        (render packet, multi-threaded renderer scheduling)
│   ├── RenderFarm/           (orchestrator, worker, job scheduler, result collector)
│   ├── RHIWGPU/              (WebGPU RHI abstraction: BindGroup, Pipeline, Texture, etc.)
│   ├── SceneRuntime/         (ECS, entities, components, audio, physics, prefabs, schedules)
│   ├── SceneFromImage/       (reference image → layout inference → scene draft)
│   ├── ScriptRuntime/        (script context, component, lifecycle, input, drawUI)
│   ├── SemanticPipeline/     (structure extraction, fingerprinting, analysis, memory)
│   ├── SequenceRuntime/      (SequenceDocument, ShotEvaluator, ClipScheduler)
│   └── SIMDCompat/           (cross-platform SIMD helpers)
├── GuavaUI/Sources/
│   ├── Bridge/CYoga/         (C bindings for Yoga)
│   ├── Font/                 (bundled fonts, FontAtlas, TextShaper)
│   ├── GuavaUIApp/           (AppConfig, window host, WGPU surface assembly)
│   ├── GuavaUIDemo/          (runnable demo entry point)
│   └── GuavaUIRuntime/       (Node, NodeTree, Layout, Color, State, Theme, DrawList wgpu renderer)
├── Editor/Sources/
│   ├── EditorApp/            (main.swift, MainWindow, panels)
│   └── EditorCore/           (editor state, project manager, AI/EditLog, GizmoSystem, etc.)
├── guava-mcp/Sources/GuavaMCP/  (MCP server exposing Guava capabilities)
├── website/                 (Vue 3 website, docs, and community portal)
├── docs/                     (architecture, roadmap, component & blueprint docs)
└── .github/workflows/        (CI matrices for engine / editor / UI / MCP + release)
```

---

## Continuous Integration

GitHub Actions workflows live under `.github/workflows/`:

- `ci-engine.yml` — Engine package matrix.
- `ci-editor.yml` — Editor package.
- `ci-guava-ui.yml` — GuavaUI package.
- `ci-guava-mcp.yml` — MCP server package.
- `release.yml` — release builds.

---

## Documentation

- **Architecture (AI-Native design, in Chinese):** [`docs/architecture.md`](docs/architecture.md)
- **Full roadmap & milestones (in Chinese):** [`docs/roadmap.md`](docs/roadmap.md)
- **Project overview (in Chinese):** [`docs/project-overview.md`](docs/project-overview.md)
- **UI design system (in Chinese):** [`docs/components/`](docs/components/)
- **MCP tools (AI tools API):** [`docs/api/ai-tools.md`](docs/api/ai-tools.md)

---

## License

Guava Engine is open source under the [Apache License 2.0](LICENSE). Third-party dependencies retain their upstream licenses; see [NOTICE](NOTICE) for attribution.
