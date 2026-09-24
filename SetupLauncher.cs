using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

internal static class SetupLauncher
{
    private const string ProductVersion = "2.5.3";
    private const string NodeChecksumsUrl = "https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt";
    private const string NodeArchiveBaseUrl = "https://nodejs.org/dist/latest-v22.x/";
    private const string AppResourceName = "LineChatSummary.App";

    private static string InstallDirectory
    {
        get
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Programs", "LineChatSummary");
        }
    }

    private static string AppPath { get { return Path.Combine(InstallDirectory, "LineChatSummary.exe"); } }
    private static string InstalledVersionPath { get { return Path.Combine(InstallDirectory, ".installed-version"); } }

    private static string LogPath
    {
        get
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "LineChatSummary", "logs", "setup-" + DateTime.Now.ToString("yyyy-MM-dd") + ".log");
        }
    }

    [STAThread]
    private static int Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;

        if (IsInstalled()) return LaunchInstalledApp();

        using (InstallProgressForm form = new InstallProgressForm())
            Application.Run(form);

        if (!InstallProgressForm.Succeeded)
            return 1;

        try
        {
            Process.Start(new ProcessStartInfo(AppPath)
            {
                WorkingDirectory = InstallDirectory,
                UseShellExecute = true
            });
            return 0;
        }
        catch (Exception exception)
        {
            WriteLog("launch_failed", exception.GetType().Name + ": " + exception.Message);
            MessageBox.Show(
                "安裝已完成，但無法自動開啟工具。請從開始功能表啟動「LINE 聊天摘要工具」。\r\n\r\n" + exception.Message,
                "LINE 聊天摘要工具", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }
    }

    private static bool IsInstalled()
    {
        try
        {
            return File.Exists(AppPath) && File.Exists(InstalledVersionPath) &&
                String.Equals(File.ReadAllText(InstalledVersionPath).Trim(), ProductVersion, StringComparison.Ordinal) &&
                FindCompatibleNode() != null;
        }
        catch { return false; }
    }

    private static int LaunchInstalledApp()
    {
        try
        {
            Process.Start(new ProcessStartInfo(AppPath)
            {
                WorkingDirectory = InstallDirectory,
                UseShellExecute = true
            });
            return 0;
        }
        catch (Exception exception)
        {
            WriteLog("launch_failed", exception.GetType().Name + ": " + exception.Message);
            MessageBox.Show(
                "無法開啟已安裝的工具。請重新執行 LineChatSummary-Codex.exe 修復安裝。\r\n\r\n" + exception.Message,
                "LINE 聊天摘要工具", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }
    }

    private static void Install(Action<string> setStatus)
    {
        try
        {
            Directory.CreateDirectory(InstallDirectory);
            string nodeSource;

            setStatus("正在檢查 Node.js 版本…");
            string existingNode = FindCompatibleNode();
            if (existingNode == null)
            {
                setStatus("正在從 Node.js 官方網站下載相容執行環境…");
                InstallPrivateNode(setStatus);
                nodeSource = "downloaded_node_22_lts";
            }
            else
            {
                nodeSource = "existing_node";
            }

            setStatus("正在安裝 LINE 聊天摘要工具…");
            WriteEmbeddedResource(AppResourceName, AppPath);

            setStatus("正在建立開始功能表捷徑…");
            try { CreateStartMenuShortcut(AppPath); }
            catch (Exception exception) { WriteLog("shortcut_warning", exception.GetType().Name); }

            File.WriteAllText(InstalledVersionPath, ProductVersion, new UTF8Encoding(false));

            WriteLog("install_complete", "version=" + ProductVersion + " nodeSource=" + nodeSource + " codexAndLine=not_installed");
            setStatus("安裝完成，正在開啟工具…");
        }
        catch (Exception exception)
        {
            WriteLog("install_failed", exception.GetType().Name + ": " + exception.Message);
            throw;
        }
    }

    private static string FindCompatibleNode()
    {
        string localNode = Path.Combine(InstallDirectory, "runtime", "node", "node.exe");
        if (File.Exists(localNode) && IsCompatibleNode(localNode))
            return localNode;

        string pathValue = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (string folder in pathValue.Split(Path.PathSeparator))
        {
            if (String.IsNullOrWhiteSpace(folder)) continue;
            string candidate = Path.Combine(folder.Trim().Trim('"'), "node.exe");
            if (File.Exists(candidate) && IsCompatibleNode(candidate))
                return candidate;
        }

        string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string standard = Path.Combine(programFiles, "nodejs", "node.exe");
        if (File.Exists(standard) && IsCompatibleNode(standard))
            return standard;

        string programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        string x86 = Path.Combine(programFilesX86, "nodejs", "node.exe");
        if (File.Exists(x86) && IsCompatibleNode(x86))
            return x86;

        return null;
    }

    private static bool IsCompatibleNode(string executable)
    {
        try
        {
            ProcessStartInfo info = new ProcessStartInfo();
            info.FileName = executable;
            info.Arguments = "-p \"process.versions.node + ' ' + process.platform + ' ' + process.arch\"";
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WindowStyle = ProcessWindowStyle.Hidden;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;

            using (Process process = Process.Start(info))
            {
                if (process == null || !process.WaitForExit(6000))
                {
                    if (process != null) process.Kill();
                    return false;
                }
                string[] fields = process.StandardOutput.ReadToEnd().Trim().Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
                int major;
                return fields.Length == 3 && fields[1] == "win32" && fields[2] == "x64" &&
                    Int32.TryParse(fields[0].Split('.')[0], out major) && major >= 22;
            }
        }
        catch { return false; }
    }

    private static void InstallPrivateNode(Action<string> setStatus)
    {
        string workDirectory = Path.Combine(Path.GetTempPath(), "LineChatSummarySetup-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(workDirectory);
        try
        {
            string checksums;
            using (WebClient client = CreateWebClient())
                checksums = client.DownloadString(NodeChecksumsUrl);

            Match match = Regex.Match(
                checksums,
                @"(?m)^([a-fA-F0-9]{64})\s+(node-(v22\.\d+\.\d+-win-x64\.zip))\s*$");
            if (!match.Success)
                throw new InvalidOperationException("無法從 Node.js 官方校驗清單辨識 Windows x64 套件。");

            string expectedHash = match.Groups[1].Value.ToLowerInvariant();
            string archiveName = match.Groups[2].Value;
            string archivePath = Path.Combine(workDirectory, archiveName);
            setStatus("正在下載 Node.js 22 LTS；下載時間依網路速度而異…");
            using (WebClient client = CreateWebClient())
                client.DownloadFile(NodeArchiveBaseUrl + archiveName, archivePath);

            setStatus("正在驗證 Node.js 安裝檔…");
            string actualHash = ComputeSha256(archivePath);
            if (!String.Equals(actualHash, expectedHash, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Node.js 安裝檔的 SHA-256 驗證失敗，已停止安裝。");

            string extractedDirectory = Path.Combine(workDirectory, "node");
            Directory.CreateDirectory(extractedDirectory);
            ExtractNodeArchive(archivePath, archiveName, extractedDirectory);
            string extractedNode = Path.Combine(extractedDirectory, "node.exe");
            if (!File.Exists(extractedNode) || !IsCompatibleNode(extractedNode))
                throw new InvalidDataException("下載的 Node.js 執行環境無法啟動或版本不相容。");

            string runtimeDirectory = Path.Combine(InstallDirectory, "runtime", "node");
            string runtimeParent = Path.GetDirectoryName(runtimeDirectory);
            Directory.CreateDirectory(runtimeParent);
            if (Directory.Exists(runtimeDirectory))
                Directory.Delete(runtimeDirectory, true);
            Directory.Move(extractedDirectory, runtimeDirectory);
        }
        finally
        {
            try { if (Directory.Exists(workDirectory)) Directory.Delete(workDirectory, true); }
            catch { }
        }
    }

    private static WebClient CreateWebClient()
    {
        WebClient client = new WebClient();
        client.Headers[HttpRequestHeader.UserAgent] = "LineChatSummarySetup/2.5.3";
        return client;
    }

    private static string ComputeSha256(string path)
    {
        using (SHA256 sha = SHA256.Create())
        using (FileStream stream = File.OpenRead(path))
        {
            byte[] hash = sha.ComputeHash(stream);
            StringBuilder text = new StringBuilder(hash.Length * 2);
            foreach (byte value in hash) text.Append(value.ToString("x2"));
            return text.ToString();
        }
    }

    private static void ExtractNodeArchive(string archivePath, string archiveName, string destination)
    {
        string prefix = archiveName.Substring(0, archiveName.Length - 4) + "/";
        string root = Path.GetFullPath(destination).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;

        using (FileStream file = File.OpenRead(archivePath))
        using (ZipArchive archive = new ZipArchive(file, ZipArchiveMode.Read))
        {
            foreach (ZipArchiveEntry entry in archive.Entries)
            {
                if (!entry.FullName.StartsWith(prefix, StringComparison.Ordinal)) continue;
                string relative = entry.FullName.Substring(prefix.Length).Replace('/', Path.DirectorySeparatorChar);
                if (String.IsNullOrEmpty(relative)) continue;

                string target = Path.GetFullPath(Path.Combine(destination, relative));
                if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("Node.js 壓縮檔含有無效路徑。");

                if (entry.FullName.EndsWith("/", StringComparison.Ordinal))
                {
                    Directory.CreateDirectory(target);
                    continue;
                }

                Directory.CreateDirectory(Path.GetDirectoryName(target));
                using (Stream input = entry.Open())
                using (FileStream output = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None))
                    input.CopyTo(output);
            }
        }
    }

    private static void WriteEmbeddedResource(string resourceName, string destination)
    {
        using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName))
        {
            if (input == null)
                throw new InvalidOperationException("安裝包缺少摘要工具程式元件。");
            string parent = Path.GetDirectoryName(destination);
            if (!Directory.Exists(parent)) Directory.CreateDirectory(parent);
            using (FileStream output = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None))
                input.CopyTo(output);
        }
    }

    private static void CreateStartMenuShortcut(string targetPath)
    {
        string programs = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
        string folder = Path.Combine(programs, "LINE 聊天摘要工具");
        Directory.CreateDirectory(folder);
        string shortcutPath = Path.Combine(folder, "LINE 聊天摘要工具.lnk");

        Type shellType = Type.GetTypeFromProgID("WScript.Shell");
        if (shellType == null) throw new InvalidOperationException("Windows 捷徑服務無法使用。");
        object shell = Activator.CreateInstance(shellType);
        object shortcut = null;
        try
        {
            shortcut = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { shortcutPath });
            Type shortcutType = shortcut.GetType();
            shortcutType.InvokeMember("TargetPath", BindingFlags.SetProperty, null, shortcut, new object[] { targetPath });
            shortcutType.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, shortcut, new object[] { InstallDirectory });
            shortcutType.InvokeMember("Description", BindingFlags.SetProperty, null, shortcut, new object[] { "LINE 聊天摘要工具" });
            shortcutType.InvokeMember("Save", BindingFlags.InvokeMethod, null, shortcut, null);
        }
        finally
        {
            if (shortcut != null && Marshal.IsComObject(shortcut)) Marshal.ReleaseComObject(shortcut);
            if (Marshal.IsComObject(shell)) Marshal.ReleaseComObject(shell);
        }
    }

    private static void WriteLog(string eventName, string detail)
    {
        try
        {
            string parent = Path.GetDirectoryName(LogPath);
            Directory.CreateDirectory(parent);
            string safe = (detail ?? String.Empty).Replace("\r", " ").Replace("\n", " ");
            File.AppendAllText(LogPath,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + eventName + " detail=" + safe + Environment.NewLine,
                new UTF8Encoding(false));
        }
        catch { }
    }

    private sealed class InstallProgressForm : Form
    {
        private readonly Label statusLabel;
        private readonly ProgressBar progressBar;
        private readonly BackgroundWorker worker;
        internal static bool Succeeded;

        internal InstallProgressForm()
        {
            Succeeded = false;
            Text = "LINE 聊天摘要工具安裝";
            ClientSize = new System.Drawing.Size(460, 145);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ControlBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ShowInTaskbar = true;

            Label heading = new Label();
            heading.AutoSize = false;
            heading.Location = new System.Drawing.Point(24, 20);
            heading.Size = new System.Drawing.Size(410, 25);
            heading.Font = new System.Drawing.Font("Microsoft JhengHei UI", 11F, System.Drawing.FontStyle.Bold);
            heading.Text = "正在安裝 LINE 聊天摘要工具";

            statusLabel = new Label();
            statusLabel.AutoSize = false;
            statusLabel.Location = new System.Drawing.Point(25, 55);
            statusLabel.Size = new System.Drawing.Size(410, 23);
            statusLabel.Font = new System.Drawing.Font("Microsoft JhengHei UI", 9F);
            statusLabel.Text = "正在準備…";

            progressBar = new ProgressBar();
            progressBar.Location = new System.Drawing.Point(25, 91);
            progressBar.Size = new System.Drawing.Size(410, 12);
            progressBar.Style = ProgressBarStyle.Marquee;
            progressBar.MarqueeAnimationSpeed = 24;

            Controls.Add(heading);
            Controls.Add(statusLabel);
            Controls.Add(progressBar);

            worker = new BackgroundWorker();
            worker.DoWork += delegate(object sender, DoWorkEventArgs args)
            {
                Install(SetStatus);
            };
            worker.RunWorkerCompleted += delegate(object sender, RunWorkerCompletedEventArgs args)
            {
                if (args.Error != null)
                {
                    progressBar.Style = ProgressBarStyle.Blocks;
                    MessageBox.Show(this,
                        "安裝沒有完成。請確認網路連線後重試。\r\n\r\n" + args.Error.GetBaseException().Message +
                        "\r\n\r\n安裝記錄：" + LogPath,
                        "LINE 聊天摘要工具安裝失敗", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    Close();
                    return;
                }

                Succeeded = true;
                Close();
            };
            Shown += delegate { worker.RunWorkerAsync(); };
        }

        private void SetStatus(string value)
        {
            if (IsDisposed || !IsHandleCreated) return;
            try { BeginInvoke(new MethodInvoker(delegate { if (!IsDisposed) statusLabel.Text = value; })); }
            catch { }
        }
    }
}
