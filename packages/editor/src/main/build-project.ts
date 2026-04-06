/**
 * build-project.ts — Standalone game build pipeline.
 *
 * Compiles the guava-player binary, copies engine core assets and project
 * assets into a platform-specific distribution layout.
 *
 * macOS  → {output}/GameName.app/Contents/{MacOS,Resources,Frameworks,...}
 * Windows → {output}/GameName/{guava-player.exe, assets/, ...}
 * Linux  → {output}/game-name/{bin/guava-player, share/assets/, ...}
 */
import { spawn } from "child_process";
import path from "path";
import fs from "fs/promises";
import { existsSync } from "fs";

export type BuildPlatform = "macos" | "windows" | "linux";

export interface BuildOptions {
  /** Absolute path to the user's project root (contains .guava) */
  projectPath: string;
  /** Where to write the distributable output */
  outputDir: string;
  /** Display name for the game (from .guava "name") */
  gameName: string;
  /** Target platform (defaults to current) */
  platform?: BuildPlatform;
  /** Optimization level */
  optimize?: "Debug" | "ReleaseSafe" | "ReleaseFast";
}

export interface BuildProgress {
  stage: string;
  percent: number;
  detail?: string;
}

function currentPlatform(): BuildPlatform {
  switch (process.platform) {
    case "darwin": return "macos";
    case "win32": return "windows";
    default: return "linux";
  }
}

function engineRootDir(): string {
  return path.resolve(__dirname, "../../..", "engine");
}

/**
 * Build a standalone distributable game package.
 *
 * @param opts  Build configuration
 * @param onProgress  Progress callback
 * @returns The path to the output package
 */
export async function buildProject(
  opts: BuildOptions,
  onProgress?: (p: BuildProgress) => void,
): Promise<string> {
  const platform = opts.platform ?? currentPlatform();
  const optimize = opts.optimize ?? "ReleaseSafe";
  const engineRoot = engineRootDir();

  const report = (stage: string, percent: number, detail?: string) =>
    onProgress?.({ stage, percent, detail });

  // ── Stage 1: Compile guava-player ────────────────────────────────
  report("compile", 0, "Compiling guava-player...");
  await zigBuildPlayer(engineRoot, optimize);
  report("compile", 30, "Compilation complete");

  // ── Stage 2: Assemble output directory ───────────────────────────
  report("package", 35, "Assembling package...");
  const outPath = await assemblePackage(engineRoot, opts, platform);
  report("package", 90, "Package assembled");

  // ── Stage 3: Platform post-processing ────────────────────────────
  if (platform === "macos") {
    report("finalize", 92, "Fixing dylib references...");
    await fixMacOSDylibs(outPath);
  }

  report("done", 100, `Build complete: ${outPath}`);
  return outPath;
}

// ─── Zig compilation ──────────────────────────────────────────────

function zigBuildPlayer(engineRoot: string, optimize: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const args = ["build", "player", `-Doptimize=${optimize}`];
    const proc = spawn("zig", args, {
      cwd: engineRoot,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stderr = "";
    proc.stderr?.on("data", (d: Buffer) => { stderr += d.toString(); });
    proc.on("exit", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`zig build player failed (code ${code}):\n${stderr}`));
    });
    proc.on("error", reject);
  });
}

// ─── Package assembly ─────────────────────────────────────────────

async function assemblePackage(
  engineRoot: string,
  opts: BuildOptions,
  platform: BuildPlatform,
): Promise<string> {
  const { outputDir, projectPath, gameName } = opts;

  // Platform-specific layout
  let binDir: string;
  let assetsDir: string;
  let bundleRoot: string;

  switch (platform) {
    case "macos": {
      bundleRoot = path.join(outputDir, `${gameName}.app`, "Contents");
      binDir = path.join(bundleRoot, "MacOS");
      assetsDir = path.join(bundleRoot, "Resources");
      break;
    }
    case "windows": {
      bundleRoot = path.join(outputDir, gameName);
      binDir = bundleRoot;
      assetsDir = bundleRoot;
      break;
    }
    default: {
      const safeName = gameName.toLowerCase().replace(/\s+/g, "-");
      bundleRoot = path.join(outputDir, safeName);
      binDir = path.join(bundleRoot, "bin");
      assetsDir = path.join(bundleRoot, "share");
      break;
    }
  }

  // Create directories
  await fs.mkdir(binDir, { recursive: true });
  await fs.mkdir(assetsDir, { recursive: true });

  // 1. Copy player binary
  const playerBinName = platform === "windows" ? "guava-player.exe" : "guava-player";
  const playerSrc = path.join(engineRoot, "zig-out", "bin", playerBinName);
  const playerDst = path.join(binDir, playerBinName);
  await fs.copyFile(playerSrc, playerDst);
  if (platform !== "windows") {
    await fs.chmod(playerDst, 0o755);
  }

  // 2. Copy engine core assets (shaders are always needed)
  const engineAssetsDir = path.join(engineRoot, "assets");
  for (const subdir of ["shaders"]) {
    const src = path.join(engineAssetsDir, subdir);
    const dst = path.join(assetsDir, "assets", subdir);
    if (existsSync(src)) {
      await copyDirRecursive(src, dst, [".meta", ".DS_Store"]);
    }
  }

  // Copy engine logo if present
  const logoSrc = path.join(engineAssetsDir, "Guava_Engine_Logo.png");
  if (existsSync(logoSrc)) {
    const logoDst = path.join(assetsDir, "assets", "Guava_Engine_Logo.png");
    await fs.mkdir(path.dirname(logoDst), { recursive: true });
    await fs.copyFile(logoSrc, logoDst);
  }

  // 3. Copy project assets (scenes, scripts, models, materials, etc.)
  const projectContentDir = path.join(projectPath, "Content");
  if (existsSync(projectContentDir)) {
    await copyDirRecursive(
      projectContentDir,
      path.join(assetsDir, "Content"),
      [".meta", ".DS_Store"],
    );
  }

  // Copy project scripts from engine runtime location
  const projectScriptsDir = path.join(engineRoot, "assets", "scripts");
  if (existsSync(projectScriptsDir)) {
    await copyDirRecursive(
      projectScriptsDir,
      path.join(assetsDir, "assets", "scripts"),
      [".meta", ".DS_Store"],
    );
  }

  // 4. Copy derived assets (pre-processed models, textures)
  const derivedDir = path.join(projectPath, "Derived");
  if (existsSync(derivedDir)) {
    await copyDirRecursive(
      derivedDir,
      path.join(assetsDir, "Derived"),
      [".meta", ".DS_Store"],
    );
  }

  // Also copy engine derived assets (shared textures, meshes)
  for (const subdir of ["models", "textures"]) {
    const src = path.join(engineAssetsDir, "derived", subdir);
    const dst = path.join(assetsDir, "assets", "derived", subdir);
    if (existsSync(src)) {
      await copyDirRecursive(src, dst, [".meta", ".DS_Store"]);
    }
  }

  // 5. Copy .guava project config
  const guavaConfigSrc = path.join(projectPath, ".guava");
  if (existsSync(guavaConfigSrc)) {
    await fs.copyFile(guavaConfigSrc, path.join(assetsDir, ".guava"));
  }

  // 6. Platform-specific extras
  if (platform === "macos") {
    await writeMacOSInfoPlist(bundleRoot, gameName);

    // Copy SDL3 framework
    const sdlSrc = "/opt/homebrew/lib/libSDL3.0.dylib";
    if (existsSync(sdlSrc)) {
      const fwDir = path.join(bundleRoot, "Frameworks");
      await fs.mkdir(fwDir, { recursive: true });
      await fs.copyFile(sdlSrc, path.join(fwDir, "libSDL3.0.dylib"));
    }
  }

  return platform === "macos"
    ? path.join(outputDir, `${gameName}.app`)
    : bundleRoot;
}

// ─── macOS specific ───────────────────────────────────────────────

async function writeMacOSInfoPlist(contentsDir: string, gameName: string): Promise<void> {
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>guava-player</string>
  <key>CFBundleIdentifier</key>
  <string>com.guava.${gameName.toLowerCase().replace(/\s+/g, "-")}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${gameName}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
`;
  await fs.writeFile(path.join(contentsDir, "Info.plist"), plist, "utf-8");
}

async function fixMacOSDylibs(appPath: string): Promise<void> {
  const playerBin = path.join(appPath, "Contents", "MacOS", "guava-player");
  if (!existsSync(playerBin)) return;

  // Fix SDL3 rpath
  await runCommand("install_name_tool", [
    "-change",
    "/opt/homebrew/lib/libSDL3.0.dylib",
    "@executable_path/../Frameworks/libSDL3.0.dylib",
    playerBin,
  ]);
}

// ─── Utilities ────────────────────────────────────────────────────

async function copyDirRecursive(
  src: string,
  dst: string,
  excludeExtensions: string[],
): Promise<void> {
  await fs.mkdir(dst, { recursive: true });
  const entries = await fs.readdir(src, { withFileTypes: true });
  for (const entry of entries) {
    const srcPath = path.join(src, entry.name);
    const dstPath = path.join(dst, entry.name);

    if (excludeExtensions.some((ext) => entry.name.endsWith(ext))) continue;

    if (entry.isDirectory()) {
      await copyDirRecursive(srcPath, dstPath, excludeExtensions);
    } else {
      await fs.copyFile(srcPath, dstPath);
    }
  }
}

function runCommand(cmd: string, args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const proc = spawn(cmd, args, { stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    proc.stderr?.on("data", (d: Buffer) => { stderr += d.toString(); });
    proc.on("exit", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`${cmd} failed (code ${code}): ${stderr}`));
    });
    proc.on("error", reject);
  });
}
