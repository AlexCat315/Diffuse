import { app } from "electron";
import path from "path";
import fs from "fs";

export interface RecentProject {
  /** Absolute path to the project root directory */
  path: string;
  /** Project display name (from .guava file or folder name fallback) */
  name: string;
  /** ISO timestamp of last open */
  lastOpened: string;
}

const RECENT_FILE = "recent-projects.json";
const MAX_RECENT = 20;

function getFilePath(): string {
  return path.join(app.getPath("userData"), RECENT_FILE);
}

export function loadRecentProjects(): RecentProject[] {
  try {
    const raw = fs.readFileSync(getFilePath(), "utf-8");
    const data = JSON.parse(raw);
    if (Array.isArray(data)) {
      return data.filter(
        (p) => typeof p.path === "string" && typeof p.name === "string",
      );
    }
  } catch {
    // File doesn't exist or is corrupted — return empty list.
  }
  return [];
}

export function saveRecentProjects(projects: RecentProject[]): void {
  try {
    fs.writeFileSync(getFilePath(), JSON.stringify(projects, null, 2), "utf-8");
  } catch (err) {
    console.warn("[RecentProjects] Failed to save:", err);
  }
}

/**
 * Add or update a project in the recent projects list.
 * Moves it to the top and trims the list to MAX_RECENT.
 */
export function addRecentProject(projectPath: string, name: string): void {
  const projects = loadRecentProjects();
  const normalized = path.resolve(projectPath);

  // Remove existing entry for same path (case-insensitive on macOS)
  const filtered = projects.filter(
    (p) => path.resolve(p.path).toLowerCase() !== normalized.toLowerCase(),
  );

  filtered.unshift({
    path: normalized,
    name,
    lastOpened: new Date().toISOString(),
  });

  saveRecentProjects(filtered.slice(0, MAX_RECENT));
}

export function removeRecentProject(projectPath: string): void {
  const projects = loadRecentProjects();
  const normalized = path.resolve(projectPath);
  const filtered = projects.filter(
    (p) => path.resolve(p.path).toLowerCase() !== normalized.toLowerCase(),
  );
  saveRecentProjects(filtered);
}

/**
/**
 * Read the .guava marker file to get the project name.
 * Returns the folder name as fallback.
 */
export function readProjectName(projectPath: string): string {
  try {
    const markerPath = path.join(projectPath, ".guava");
    const raw = fs.readFileSync(markerPath, "utf-8");
    const data = JSON.parse(raw);
    if (typeof data.name === "string" && data.name.trim().length > 0) {
      return data.name;
    }
  } catch {
    // No .guava file or invalid — use folder name
  }
  return path.basename(projectPath) || "Unnamed Project";
}

/**
 * Read the start_scene path from the .guava marker file.
 * Returns undefined if not found.
 */
export function readStartScene(projectPath: string): string | undefined {
  try {
    const markerPath = path.join(projectPath, ".guava");
    const raw = fs.readFileSync(markerPath, "utf-8");
    const data = JSON.parse(raw);
    if (typeof data.start_scene === "string" && data.start_scene.trim().length > 0) {
      return data.start_scene;
    }
  } catch {
    // ignore
  }
  return undefined;
}

/**
 * Check if a path contains a valid Guava project (.guava marker exists).
 */
export function isGuavaProject(projectPath: string): boolean {
  try {
    const markerPath = path.join(projectPath, ".guava");
    return fs.existsSync(markerPath);
  } catch {
    return false;
  }
}

/**
 * Create a new Guava project at the given path.
 * Creates the directory structure and .guava marker file.
 */
export function createNewProject(projectPath: string, projectName: string): void {
  const normalized = path.resolve(projectPath);

  // Create directory structure
  fs.mkdirSync(normalized, { recursive: true });
  fs.mkdirSync(path.join(normalized, "Content", "Scenes"), { recursive: true });
  fs.mkdirSync(path.join(normalized, "Derived"), { recursive: true });

  // Write .guava marker file
  const marker = {
    version: 1,
    name: projectName,
    content_dir: "Content",
    start_scene: "Content/Scenes/Main.guava_scene",
  };
  fs.writeFileSync(
    path.join(normalized, ".guava"),
    JSON.stringify(marker, null, 2),
    "utf-8",
  );
}
