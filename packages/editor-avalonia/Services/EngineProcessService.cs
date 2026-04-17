using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Guava.Editor.Services;

/// <summary>
/// Spawns and supervises the <c>guava-engine</c> child process.
///
/// Responsibilities:
///  • Locate the binary (bundled inside .app/Contents/Resources at release,
///    or fall back to the repo path during development).
///  • Launch with <c>--editor-server --editor-port N --project-path P</c>.
///  • Stream stdout/stderr to <c>logs/engine-runtime.log</c> — never to the
///    UI console (that's reserved for engine-emitted on:console.log events).
///  • Gracefully terminate on editor shutdown.
///
/// Reconnect/restart-on-crash can be layered on later; for now a single launch
/// per editor session matches what the existing editor shell provides.
/// </summary>
public sealed class EngineProcessService : IDisposable
{
    private Process? _process;
    private StreamWriter? _logWriter;

    public int Port { get; private set; } = 9100;
    public string? ProjectPath { get; private set; }
    public bool IsRunning => _process is { HasExited: false };

    public event Action<int>? Exited; // exit code

    /// <summary>Start the engine in editor-server mode. Returns true when spawned successfully.</summary>
    public bool Start(string? projectPath = null, int port = 9100)
    {
        if (IsRunning) return true;

        Port = port;
        ProjectPath = projectPath;

        var binary = ResolveEngineBinary();
        if (binary == null) return false;

        var workingDir = Path.GetDirectoryName(binary) ?? Environment.CurrentDirectory;
        var logsDir = EnsureLogsDir();
        var logPath = Path.Combine(logsDir, "engine-runtime.log");
        try
        {
            _logWriter = new StreamWriter(new FileStream(logPath, FileMode.Append, FileAccess.Write, FileShare.Read))
            {
                AutoFlush = true,
            };
            _logWriter.WriteLine($"--- engine launch @ {DateTime.UtcNow:O} binary={binary} project={ProjectPath}");
        }
        catch { /* logs are best-effort; process still launches */ }

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = binary,
                WorkingDirectory = workingDir,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };
            psi.ArgumentList.Add("--editor-server");
            psi.ArgumentList.Add("--editor-port");
            psi.ArgumentList.Add(port.ToString());
            // project-path is optional — only supply if the directory actually exists.
            if (!string.IsNullOrEmpty(ProjectPath) && Directory.Exists(ProjectPath))
            {
                psi.ArgumentList.Add("--project-path");
                psi.ArgumentList.Add(ProjectPath);
            }

            _process = new Process { StartInfo = psi, EnableRaisingEvents = true };
            _process.OutputDataReceived += OnProcessOutput;
            _process.ErrorDataReceived += OnProcessOutput;
            _process.Exited += OnProcessExited;

            if (!_process.Start()) return false;
            _process.BeginOutputReadLine();
            _process.BeginErrorReadLine();
            return true;
        }
        catch (Exception ex)
        {
            _logWriter?.WriteLine($"--- launch failed: {ex.Message}");
            return false;
        }
    }

    public void Stop()
    {
        if (_process == null) return;
        try
        {
            if (!_process.HasExited)
            {
                _process.Kill(entireProcessTree: true);
                _process.WaitForExit(2000);
            }
        }
        catch { /* swallow — teardown */ }
        finally
        {
            _process.Dispose();
            _process = null;
            _logWriter?.Dispose();
            _logWriter = null;
        }
    }

    public void Dispose() => Stop();

    // ---------------------------------------------------------- helpers

    private void OnProcessOutput(object sender, DataReceivedEventArgs e)
    {
        if (e.Data == null) return;
        try { _logWriter?.WriteLine(e.Data); } catch { /* disk full etc. — best-effort */ }
    }

    private void OnProcessExited(object? sender, EventArgs e)
    {
        var code = _process?.ExitCode ?? -1;
        try { _logWriter?.WriteLine($"--- engine exited code={code}"); } catch { }
        Exited?.Invoke(code);
    }

    /// <summary>
    /// Resolve the <c>guava-engine</c> binary.  Ordering:
    ///   1. Environment override (GUAVA_ENGINE_BINARY).
    ///   2. Bundled at &lt;AppBundle&gt;/Contents/Resources/guava-engine (release).
    ///   3. Repo path packages/engine/zig-out/bin/guava-engine (development).
    /// </summary>
    private static string? ResolveEngineBinary()
    {
        var env = Environment.GetEnvironmentVariable("GUAVA_ENGINE_BINARY");
        if (!string.IsNullOrEmpty(env) && File.Exists(env)) return env;

        var exeDir = AppContext.BaseDirectory;

        var bundled = Path.Combine(exeDir, "..", "Resources", "guava-engine");
        if (File.Exists(bundled)) return Path.GetFullPath(bundled);

        // Walk up looking for packages/engine/zig-out/bin/guava-engine
        var dir = new DirectoryInfo(exeDir);
        while (dir != null)
        {
            var candidate = Path.Combine(dir.FullName, "packages", "engine", "zig-out", "bin", "guava-engine");
            if (File.Exists(candidate)) return candidate;
            dir = dir.Parent;
        }
        return null;
    }

    private static string DefaultProjectPath()
    {
        // Until a Launcher panel exists, prefer a workspace-scoped sample dir
        // if present; fall back to empty (engine boots without a project).
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var candidate = Path.Combine(home, ".guava", "default-project");
        return Directory.Exists(candidate) ? candidate : string.Empty;
    }

    private static string EnsureLogsDir()
    {
        var dir = Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "logs");
        dir = Path.GetFullPath(dir);
        Directory.CreateDirectory(dir);
        return dir;
    }
}
