using System;
using System.IO;

namespace Guava.Editor.Services;

/// <summary>
/// Dirt-simple logger that writes to <c>logs/editor.log</c> next to the exe
/// AND flushes to stdout so <c>dotnet run</c> shows something.
/// </summary>
public static class Log
{
    private static readonly object _sync = new();
    private static readonly string _path = InitLogPath();

    private static string InitLogPath()
    {
        try
        {
            // bin/Debug/netX/... → walk up to the editor-avalonia project dir
            // (the one that contains Guava.Editor.csproj), then write logs/editor.log.
            var dir = AppContext.BaseDirectory;
            for (int i = 0; i < 8; i++)
            {
                if (Directory.GetFiles(dir, "*.csproj").Length > 0)
                {
                    var logDir = Path.Combine(dir, "logs");
                    Directory.CreateDirectory(logDir);
                    return Path.Combine(logDir, "editor.log");
                }
                var parent = Directory.GetParent(dir);
                if (parent is null) break;
                dir = parent.FullName;
            }
        }
        catch { }
        return Path.Combine(Path.GetTempPath(), "guava-editor.log");
    }

    public static void Info(string msg)  => Write("INFO ", msg);
    public static void Warn(string msg)  => Write("WARN ", msg);
    public static void Error(string msg) => Write("ERROR", msg);

    private static void Write(string level, string msg)
    {
        var line = $"[{DateTime.Now:HH:mm:ss.fff}] {level} {msg}";
        Console.WriteLine(line);
        try
        {
            lock (_sync) File.AppendAllText(_path, line + Environment.NewLine);
        }
        catch { }
    }
}
