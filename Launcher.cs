using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

internal static class Launcher
{
    private const int Port = 48744;
    private const string AppUrl = "http://127.0.0.1:48744/";
    private const string RuntimeVersion = "better-sqlite3-multiple-ciphers@13.0.3";

    [STAThread]
    private static int Main()
    {
        Application.EnableVisualStyles();
        try
        {
            string appFolder = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "LineChatSummary", "web");
            Directory.CreateDirectory(appFolder);

            WriteEmbeddedResource("LineChatSummary.ps1", Path.Combine(appFolder, "LineChatSummary.ps1"));
            WriteEmbeddedResource("LineChatSummary.DbScript", Path.Combine(appFolder, "LineChatSummaryDb.ps1"));
            WriteEmbeddedResource("LineChatSummary.server.js", Path.Combine(appFolder, "server.js"));
            WriteEmbeddedResource("LineChatSummary.line-db.js", Path.Combine(appFolder, "line-db.js"));
            WriteEmbeddedResource("LineChatSummary.index.html", Path.Combine(appFolder, "line-chat-summary-preview.html"));
            ExtractEmbeddedRuntime("LineChatSummary.DbRuntime", Path.Combine(appFolder, "runtime-v13.0.3"));

            if (!IsServerReady())
            {
                string nodePath = FindCompatibleNode("node.exe");
                if (String.IsNullOrWhiteSpace(nodePath))
                    throw new InvalidOperationException("找不到 Node.js 22 或更新版本。LINE 本機加密資料庫元件需要 Node.js 22+，請安裝後重新啟動工具。");

                ProcessStartInfo startInfo = new ProcessStartInfo();
                startInfo.FileName = nodePath;
                startInfo.Arguments = Quote(Path.Combine(appFolder, "server.js"));
                startInfo.WorkingDirectory = appFolder;
                startInfo.UseShellExecute = false;
                startInfo.CreateNoWindow = true;
                startInfo.WindowStyle = ProcessWindowStyle.Hidden;
                startInfo.EnvironmentVariables["LINE_CHAT_SUMMARY_PORT"] = Port.ToString();
                startInfo.EnvironmentVariables["CODEX_HOME"] = Environment.GetEnvironmentVariable("CODEX_HOME") ??
                    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");

                Process.Start(startInfo);
                bool ready = false;
                for (int attempt = 0; attempt < 60; attempt++)
                {
                    if (IsServerReady())
                    {
                        ready = true;
                        break;
                    }
                    Thread.Sleep(250);
                }
                if (!ready)
                    throw new InvalidOperationException("本機網頁服務未能啟動。請確認 Node.js 可執行，並檢查 %LOCALAPPDATA%\\LineChatSummary\\logs。");
            }

            Process.Start(new ProcessStartInfo(AppUrl) { UseShellExecute = true });
            return 0;
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                "LINE 聊天摘要工具啟動失敗：\r\n\r\n" + exception.Message,
                "LINE 聊天摘要工具", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static void WriteEmbeddedResource(string resourceName, string destination)
    {
        using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName))
        {
            if (stream == null)
                throw new InvalidOperationException("應用程式元件遺失：" + resourceName);
            using (FileStream output = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None))
                stream.CopyTo(output);
        }
    }

    private static void ExtractEmbeddedRuntime(string resourceName, string destinationFolder)
    {
        string markerPath = Path.Combine(destinationFolder, ".runtime-version");
        string packagePath = Path.Combine(destinationFolder, "node_modules", "better-sqlite3-multiple-ciphers");
        string nativePath = Path.Combine(packagePath, "prebuilds", "win32-x64.node");
        string entryPath = Path.Combine(packagePath, "lib", "index.js");
        if (File.Exists(markerPath) && File.Exists(nativePath) && File.Exists(entryPath) &&
            String.Equals(File.ReadAllText(markerPath, Encoding.UTF8).Trim(), RuntimeVersion, StringComparison.Ordinal))
            return;

        Directory.CreateDirectory(destinationFolder);
        string root = Path.GetFullPath(destinationFolder).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName))
        {
            if (stream == null)
                throw new InvalidOperationException("應用程式元件遺失：" + resourceName);
            using (ZipArchive archive = new ZipArchive(stream, ZipArchiveMode.Read))
            {
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    string relative = entry.FullName.Replace('/', Path.DirectorySeparatorChar);
                    string target = Path.GetFullPath(Path.Combine(destinationFolder, relative));
                    if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("資料庫元件壓縮檔含有無效路徑。");
                    if (entry.FullName.EndsWith("/", StringComparison.Ordinal))
                    {
                        Directory.CreateDirectory(target);
                        continue;
                    }
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    using (Stream source = entry.Open())
                    using (FileStream output = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None))
                        source.CopyTo(output);
                }
            }
        }
        File.WriteAllText(markerPath, RuntimeVersion, new UTF8Encoding(false));
    }

    private static bool IsServerReady()
    {
        try
        {
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(AppUrl + "api/health");
            request.Method = "GET";
            request.Timeout = 700;
            request.ReadWriteTimeout = 700;
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                return response.StatusCode == HttpStatusCode.OK;
        }
        catch
        {
            return false;
        }
    }

    private static string FindCompatibleNode(string fileName)
    {
        string pathValue = Environment.GetEnvironmentVariable("PATH") ?? "";
        HashSet<string> visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (string folder in pathValue.Split(Path.PathSeparator))
        {
            string candidate = Path.Combine(folder.Trim('"'), fileName);
            if (File.Exists(candidate) && visited.Add(candidate) && IsCompatibleNode(candidate))
                return candidate;
        }

        string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string standard = Path.Combine(programFiles, "nodejs", fileName);
        return File.Exists(standard) && IsCompatibleNode(standard) ? standard : null;
    }

    private static bool IsCompatibleNode(string executable)
    {
        try
        {
            ProcessStartInfo info = new ProcessStartInfo();
            info.FileName = executable;
            info.Arguments = "--version";
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WindowStyle = ProcessWindowStyle.Hidden;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;
            using (Process process = Process.Start(info))
            {
                if (process == null || !process.WaitForExit(4000))
                {
                    if (process != null) process.Kill();
                    return false;
                }
                string version = process.StandardOutput.ReadToEnd().Trim().TrimStart('v');
                int major;
                return Int32.TryParse(version.Split('.')[0], out major) && major >= 22;
            }
        }
        catch
        {
            return false;
        }
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}
