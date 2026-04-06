import React, { useEffect, useState, useCallback } from "react";
import { useI18n } from "./i18n";

interface RecentProject {
  path: string;
  name: string;
  lastOpened: string;
}

interface ProjectTemplate {
  id: string;
  name: string;
  description: string;
  icon: string;
}

interface LauncherProps {
  onProjectOpened: () => void;
}

export function Launcher({ onProjectOpened }: LauncherProps) {
  const { t } = useI18n();
  const lt = t.launcher;
  const [recentProjects, setRecentProjects] = useState<RecentProject[]>([]);
  const [templates, setTemplates] = useState<ProjectTemplate[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showNewProject, setShowNewProject] = useState(false);
  const [newProjectName, setNewProjectName] = useState("");
  const [newProjectPath, setNewProjectPath] = useState("");
  const [selectedTemplate, setSelectedTemplate] = useState("empty");
  const [hovered, setHovered] = useState<string | null>(null);

  // Load recent projects and templates on mount
  useEffect(() => {
    window.guavaEngine.getRecentProjects().then(setRecentProjects);
    window.guavaEngine.getTemplates().then(setTemplates);
  }, []);

  const handleOpenProject = useCallback(async (projectPath: string) => {
    setLoading(true);
    setError(null);
    try {
      const result = await window.guavaEngine.openProject(projectPath);
      if (result.ok) {
        onProjectOpened();
      } else {
        setError(result.error ?? lt.openFailed);
        setLoading(false);
      }
    } catch (err) {
      setError(String(err));
      setLoading(false);
    }
  }, [onProjectOpened, lt]);

  const handleBrowseFolder = useCallback(async () => {
    const result = await window.guavaEngine.browseFolder();
    if (result) {
      await handleOpenProject(result);
    }
  }, [handleOpenProject]);

  const handleBrowseNewProjectLocation = useCallback(async () => {
    const result = await window.guavaEngine.browseFolder();
    if (result) {
      setNewProjectPath(result);
    }
  }, []);

  const handleCreateProject = useCallback(async () => {
    if (!newProjectName.trim() || !newProjectPath.trim()) return;
    setLoading(true);
    setError(null);
    try {
      const fullPath = newProjectPath.endsWith(newProjectName)
        ? newProjectPath
        : `${newProjectPath}/${newProjectName}`;
      const result = await window.guavaEngine.createProject(fullPath, newProjectName.trim(), selectedTemplate);
      if (result.ok) {
        onProjectOpened();
      } else {
        setError(result.error ?? lt.createFailed);
        setLoading(false);
      }
    } catch (err) {
      setError(String(err));
      setLoading(false);
    }
  }, [newProjectName, newProjectPath, selectedTemplate, onProjectOpened, lt]);

  const handleRemoveRecent = useCallback(async (e: React.MouseEvent, projectPath: string) => {
    e.stopPropagation();
    await window.guavaEngine.removeRecentProject(projectPath);
    setRecentProjects((prev) => prev.filter((p) => p.path !== projectPath));
  }, []);

  const formatDate = useCallback((iso: string) => {
    try {
      const date = new Date(iso);
      const now = new Date();
      const diffMs = now.getTime() - date.getTime();
      const diffDays = Math.floor(diffMs / (1000 * 60 * 60 * 24));
      if (diffDays === 0) return lt.today;
      if (diffDays === 1) return lt.yesterday;
      if (diffDays < 7) return lt.daysAgo.replace("{n}", String(diffDays));
      return date.toLocaleDateString();
    } catch {
      return "";
    }
  }, [lt]);

  if (loading) {
    return (
      <div style={styles.container}>
        <div style={styles.loadingArea}>
          <div style={styles.spinner} />
          <p style={styles.loadingText}>{lt.openingProject}</p>
        </div>
      </div>
    );
  }

  return (
    <div style={styles.container}>
      {/* Drag region for macOS traffic lights */}
      <div style={styles.titleBar} />

      <div style={styles.content}>
        {/* Left: Branding + Actions */}
        <div style={styles.sidebar}>
          <div style={styles.brand}>
            <div style={styles.logoIcon}>🥑</div>
            <h1 style={styles.title}>Guava Engine</h1>
            <p style={styles.subtitle}>{lt.subtitle}</p>
          </div>

          <div style={styles.actions}>
            <button
              style={styles.primaryBtn}
              onClick={() => setShowNewProject(true)}
            >
              <span style={styles.btnIcon}>+</span>
              {lt.newProject}
            </button>
            <button
              style={styles.secondaryBtn}
              onClick={handleBrowseFolder}
            >
              <span style={styles.btnIcon}>📂</span>
              {lt.openProject}
            </button>
          </div>

          {error && (
            <div style={styles.error}>
              <span style={styles.errorIcon}>⚠</span>
              {error}
            </div>
          )}
        </div>

        {/* Right: Recent Projects list or New Project form */}
        <div style={styles.main}>
          {showNewProject ? (
            <div style={styles.newProjectForm}>
              <h2 style={styles.sectionTitle}>{lt.createNewProject}</h2>

              {/* Template selector */}
              <label style={styles.label}>{lt.template}</label>
              <div style={styles.templateGrid}>
                {templates.map((tmpl) => (
                  <div
                    key={tmpl.id}
                    style={{
                      ...styles.templateCard,
                      ...(selectedTemplate === tmpl.id ? styles.templateCardSelected : {}),
                    }}
                    onClick={() => setSelectedTemplate(tmpl.id)}
                  >
                    <span style={styles.templateIcon}>{tmpl.icon}</span>
                    <span style={styles.templateName}>{tmpl.name}</span>
                    <span style={styles.templateDesc}>{tmpl.description}</span>
                  </div>
                ))}
              </div>

              <label style={styles.label}>{lt.projectName}</label>
              <input
                style={styles.input}
                type="text"
                placeholder={lt.projectNamePlaceholder}
                value={newProjectName}
                onChange={(e) => setNewProjectName(e.target.value)}
                autoFocus
                onKeyDown={(e) => {
                  if (e.key === "Enter") handleCreateProject();
                  if (e.key === "Escape") setShowNewProject(false);
                }}
              />

              <label style={styles.label}>{lt.projectLocation}</label>
              <div style={styles.pathRow}>
                <input
                  style={{ ...styles.input, flex: 1 }}
                  type="text"
                  placeholder={lt.locationPlaceholder}
                  value={newProjectPath}
                  onChange={(e) => setNewProjectPath(e.target.value)}
                />
                <button
                  style={styles.browseBtn}
                  onClick={handleBrowseNewProjectLocation}
                >
                  {lt.browse}
                </button>
              </div>

              {newProjectName && newProjectPath && (
                <p style={styles.previewPath}>
                  {lt.willCreateAt}: {newProjectPath}/{newProjectName}
                </p>
              )}

              <div style={styles.formActions}>
                <button
                  style={styles.secondaryBtn}
                  onClick={() => setShowNewProject(false)}
                >
                  {t.common.cancel}
                </button>
                <button
                  style={{
                    ...styles.primaryBtn,
                    opacity: newProjectName.trim() && newProjectPath.trim() ? 1 : 0.5,
                  }}
                  onClick={handleCreateProject}
                  disabled={!newProjectName.trim() || !newProjectPath.trim()}
                >
                  {lt.create}
                </button>
              </div>
            </div>
          ) : (
            <>
              <h2 style={styles.sectionTitle}>{lt.recentProjects}</h2>
              {recentProjects.length === 0 ? (
                <div style={styles.emptyState}>
                  <p style={styles.emptyText}>{lt.noRecentProjects}</p>
                  <p style={styles.emptyHint}>{lt.getStarted}</p>
                </div>
              ) : (
                <div style={styles.projectList}>
                  {recentProjects.map((project) => (
                    <div
                      key={project.path}
                      style={{
                        ...styles.projectItem,
                        ...(hovered === project.path ? styles.projectItemHover : {}),
                      }}
                      onClick={() => handleOpenProject(project.path)}
                      onMouseEnter={() => setHovered(project.path)}
                      onMouseLeave={() => setHovered(null)}
                    >
                      <div style={styles.projectIcon}>📁</div>
                      <div style={styles.projectInfo}>
                        <span style={styles.projectName}>{project.name}</span>
                        <span style={styles.projectPath}>{project.path}</span>
                      </div>
                      <div style={styles.projectMeta}>
                        <span style={styles.projectDate}>
                          {formatDate(project.lastOpened)}
                        </span>
                        <button
                          style={{
                            ...styles.removeBtn,
                            opacity: hovered === project.path ? 1 : 0,
                          }}
                          onClick={(e) => handleRemoveRecent(e, project.path)}
                          title={lt.removeFromRecent}
                        >
                          ✕
                        </button>
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </>
          )}
        </div>
      </div>
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  container: {
    display: "flex",
    flexDirection: "column",
    height: "100vh",
    background: "#1e1e2e",
    color: "#cdd6f4",
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
  },
  titleBar: {
    height: 38,
    // @ts-expect-error Electron-specific CSS property for window dragging
    WebkitAppRegion: "drag",
    flexShrink: 0,
  },
  content: {
    display: "flex",
    flex: 1,
    minHeight: 0,
  },
  sidebar: {
    width: 280,
    padding: "24px 28px",
    display: "flex",
    flexDirection: "column",
    gap: 24,
    borderRight: "1px solid #313244",
    flexShrink: 0,
  },
  brand: {
    marginBottom: 8,
  },
  logoIcon: {
    fontSize: 48,
    marginBottom: 12,
  },
  title: {
    fontSize: 22,
    fontWeight: 700,
    color: "#cdd6f4",
    margin: 0,
  },
  subtitle: {
    fontSize: 13,
    color: "#6c7086",
    margin: "6px 0 0",
  },
  actions: {
    display: "flex",
    flexDirection: "column",
    gap: 10,
  },
  primaryBtn: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "10px 16px",
    background: "#89b4fa",
    color: "#1e1e2e",
    border: "none",
    borderRadius: 6,
    fontSize: 14,
    fontWeight: 600,
    cursor: "pointer",
    transition: "background 0.15s",
  },
  secondaryBtn: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "10px 16px",
    background: "#313244",
    color: "#cdd6f4",
    border: "1px solid #45475a",
    borderRadius: 6,
    fontSize: 14,
    fontWeight: 500,
    cursor: "pointer",
    transition: "background 0.15s",
  },
  btnIcon: {
    fontSize: 16,
  },
  error: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "10px 14px",
    background: "rgba(243, 139, 168, 0.1)",
    border: "1px solid rgba(243, 139, 168, 0.3)",
    borderRadius: 6,
    color: "#f38ba8",
    fontSize: 13,
  },
  errorIcon: {
    flexShrink: 0,
  },
  main: {
    flex: 1,
    padding: "24px 32px",
    overflowY: "auto",
    minWidth: 0,
  },
  sectionTitle: {
    fontSize: 15,
    fontWeight: 600,
    color: "#a6adc8",
    margin: "0 0 16px",
    textTransform: "uppercase" as const,
    letterSpacing: "0.05em",
  },
  projectList: {
    display: "flex",
    flexDirection: "column",
    gap: 2,
  },
  projectItem: {
    display: "flex",
    alignItems: "center",
    gap: 12,
    padding: "12px 14px",
    borderRadius: 6,
    cursor: "pointer",
    transition: "background 0.12s",
  },
  projectItemHover: {
    background: "#313244",
  },
  projectIcon: {
    fontSize: 24,
    flexShrink: 0,
  },
  projectInfo: {
    flex: 1,
    display: "flex",
    flexDirection: "column",
    gap: 2,
    minWidth: 0,
  },
  projectName: {
    fontSize: 14,
    fontWeight: 500,
    color: "#cdd6f4",
  },
  projectPath: {
    fontSize: 12,
    color: "#6c7086",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap" as const,
  },
  projectMeta: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    flexShrink: 0,
  },
  projectDate: {
    fontSize: 12,
    color: "#6c7086",
  },
  removeBtn: {
    background: "transparent",
    border: "none",
    color: "#6c7086",
    cursor: "pointer",
    fontSize: 12,
    padding: "2px 4px",
    borderRadius: 3,
    transition: "opacity 0.15s, color 0.15s",
  },
  emptyState: {
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "center",
    height: "60%",
    gap: 8,
  },
  emptyText: {
    fontSize: 15,
    color: "#6c7086",
    margin: 0,
  },
  emptyHint: {
    fontSize: 13,
    color: "#585b70",
    margin: 0,
  },
  newProjectForm: {
    maxWidth: 480,
  },
  templateGrid: {
    display: "grid",
    gridTemplateColumns: "repeat(auto-fill, minmax(140px, 1fr))",
    gap: 10,
    marginBottom: 4,
  },
  templateCard: {
    display: "flex",
    flexDirection: "column" as const,
    alignItems: "center",
    gap: 6,
    padding: "14px 10px",
    background: "#181825",
    border: "2px solid #313244",
    borderRadius: 8,
    cursor: "pointer",
    transition: "border-color 0.15s, background 0.15s",
  },
  templateCardSelected: {
    borderColor: "#89b4fa",
    background: "rgba(137, 180, 250, 0.08)",
  },
  templateIcon: {
    fontSize: 28,
  },
  templateName: {
    fontSize: 13,
    fontWeight: 600,
    color: "#cdd6f4",
    textAlign: "center" as const,
  },
  templateDesc: {
    fontSize: 11,
    color: "#6c7086",
    textAlign: "center" as const,
    lineHeight: 1.3,
  },
  label: {
    display: "block",
    fontSize: 13,
    fontWeight: 500,
    color: "#a6adc8",
    marginBottom: 6,
    marginTop: 16,
  },
  input: {
    display: "block",
    width: "100%",
    padding: "9px 12px",
    background: "#181825",
    border: "1px solid #45475a",
    borderRadius: 6,
    color: "#cdd6f4",
    fontSize: 14,
    outline: "none",
    boxSizing: "border-box" as const,
  },
  pathRow: {
    display: "flex",
    gap: 8,
  },
  browseBtn: {
    padding: "9px 14px",
    background: "#313244",
    color: "#cdd6f4",
    border: "1px solid #45475a",
    borderRadius: 6,
    fontSize: 13,
    cursor: "pointer",
    whiteSpace: "nowrap" as const,
    flexShrink: 0,
  },
  previewPath: {
    fontSize: 12,
    color: "#6c7086",
    margin: "10px 0 0",
    wordBreak: "break-all" as const,
  },
  formActions: {
    display: "flex",
    gap: 10,
    justifyContent: "flex-end",
    marginTop: 24,
  },
  loadingArea: {
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "center",
    height: "100%",
    gap: 16,
  },
  spinner: {
    width: 24,
    height: 24,
    border: "3px solid #45475a",
    borderTop: "3px solid #89b4fa",
    borderRadius: "50%",
    animation: "spin 1s linear infinite",
  },
  loadingText: {
    fontSize: 14,
    color: "#6c7086",
  },
};
