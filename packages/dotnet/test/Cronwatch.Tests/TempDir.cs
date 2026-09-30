using System;
using System.IO;
using Microsoft.Data.Sqlite;

namespace Cronwatch.Tests;

/// <summary>
/// A directory of the test's own, deleted when disposed. SQLite's pooled connections are cleared
/// first, so no handle keeps a file open while it is deleted (Windows refuses that).
/// </summary>
internal sealed class TempDir : IDisposable
{
    public TempDir()
    {
        Path = Directory.CreateTempSubdirectory("cronwatch-dotnet-").FullName;
    }

    public string Path { get; }

    public string File(string name) => System.IO.Path.Combine(Path, name);

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        for (int attempt = 0; ; attempt++)
        {
            try
            {
                Directory.Delete(Path, recursive: true);
                return;
            }
            catch (IOException) when (attempt < 20)
            {
                System.Threading.Thread.Sleep(50);
            }
            catch (UnauthorizedAccessException) when (attempt < 20)
            {
                System.Threading.Thread.Sleep(50);
            }
            catch (DirectoryNotFoundException)
            {
                return;
            }
        }
    }
}
