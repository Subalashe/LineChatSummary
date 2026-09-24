# LINE 群組聊天儲存與摘要工具
# Target: Windows PowerShell 5.1, .NET Framework UI Automation and Windows Forms.
# Chat text and API credentials are never written to the application log.

param(
    [ValidateSet('PrepareSummary', 'CleanupTranscript')]
    [string]$Mode = 'PrepareSummary',
    [string]$RequestPath = ''
)

$ErrorActionPreference = 'Stop'

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        '無法載入 Windows 桌面元件。請用 Windows PowerShell 5.1 啟動此工具。',
        'LINE 群組摘要工具', [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}

if (-not ('LineChatSummaryNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class LineChatSummaryWindowInfo {
    public IntPtr Handle { get; set; }
    public int ProcessId { get; set; }
    public int ZOrder { get; set; }
    public int Left { get; set; }
    public int Top { get; set; }
    public int Width { get; set; }
    public int Height { get; set; }
    public string WindowClass { get; set; }
    public bool IsMinimized { get; set; }
    public bool IsVisible { get; set; }
    public bool RelatedToLine { get; set; }
    public double UiaLeft { get; set; }
    public double UiaTop { get; set; }
    public double UiaScaleX { get; set; }
    public double UiaScaleY { get; set; }
}

public static class LineChatSummaryNative {
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] private struct RECT {
        public int Left; public int Top; public int Right; public int Bottom;
    }
    [StructLayout(LayoutKind.Sequential)] private struct POINT {
        public int X; public int Y;
    }
    [StructLayout(LayoutKind.Sequential)] private struct WINDOWPLACEMENT {
        public uint Length; public uint Flags; public uint ShowCmd;
        public POINT MinPosition; public POINT MaxPosition; public RECT NormalPosition;
    }
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr extraData);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hWnd, uint command);
    [DllImport("user32.dll")] private static extern IntPtr GetParent(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern IntPtr GetLastActivePopup(IntPtr hWnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr FindWindow(string className, string windowName);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder className, int maxCount);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc callback, IntPtr extraData);
    [DllImport("user32.dll", SetLastError=true)] private static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT placement);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", SetLastError=true)] private static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint flags);
    [DllImport("user32.dll", SetLastError=true)] private static extern bool PostMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

    public static List<LineChatSummaryWindowInfo> GetWindows(int[] processIds) {
        var wanted = new HashSet<int>(processIds);
        var result = new List<LineChatSummaryWindowInfo>();
        int zOrder = 0;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            int currentZOrder = zOrder++;
            uint rawPid;
            GetWindowThreadProcessId(hWnd, out rawPid);
            int pid = unchecked((int)rawPid);
            if (!wanted.Contains(pid)) return true;
            RECT rect;
            if (!GetWindowRect(hWnd, out rect)) return true;
            int width = rect.Right - rect.Left;
            int height = rect.Bottom - rect.Top;
            bool minimized = IsIconic(hWnd);
            bool visible = IsWindowVisible(hWnd);
            if (minimized || width < 300 || height < 220) {
                WINDOWPLACEMENT placement = new WINDOWPLACEMENT();
                placement.Length = (uint)Marshal.SizeOf(typeof(WINDOWPLACEMENT));
                if (GetWindowPlacement(hWnd, ref placement)) {
                    RECT normal = placement.NormalPosition;
                    if (normal.Right - normal.Left >= 300 && normal.Bottom - normal.Top >= 220) {
                        rect = normal;
                        width = rect.Right - rect.Left;
                        height = rect.Bottom - rect.Top;
                    }
                }
            }
            // Include hidden and minimized LINE windows so UI Automation can try passive access.
            if (width < 300 || height < 220) return true;
            result.Add(new LineChatSummaryWindowInfo {
                Handle = hWnd, ProcessId = pid, ZOrder = currentZOrder, Left = rect.Left, Top = rect.Top,
                Width = width, Height = height, IsMinimized = minimized, IsVisible = visible
            });
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static bool IsWindowRelatedToLine(IntPtr hWnd, IntPtr parentHandle, int[] processIds) {
        if (hWnd == IntPtr.Zero) return false;
        var wanted = new HashSet<int>(processIds);
        var seen = new HashSet<IntPtr>();
        IntPtr current = hWnd;
        for (int depth = 0; current != IntPtr.Zero && depth < 16 && seen.Add(current); depth++) {
            if (current == parentHandle) return true;
            uint rawPid;
            GetWindowThreadProcessId(current, out rawPid);
            if (wanted.Contains(unchecked((int)rawPid))) return true;
            IntPtr next = GetWindow(current, 4); // GW_OWNER
            if (next == IntPtr.Zero) next = GetParent(current);
            current = next;
        }
        return false;
    }

    private static void AddPopupWindow(List<LineChatSummaryWindowInfo> result, HashSet<IntPtr> seen,
            IntPtr hWnd, int zOrder, HashSet<int> wanted, IntPtr parentHandle, bool force, bool allowUnrelated) {
        if (hWnd == IntPtr.Zero || !seen.Add(hWnd) || !IsWindowVisible(hWnd) || IsIconic(hWnd)) return;
        uint rawPid;
        GetWindowThreadProcessId(hWnd, out rawPid);
        int pid = unchecked((int)rawPid);
        RECT rect;
        if (!GetWindowRect(hWnd, out rect)) return;
        int width = rect.Right - rect.Left;
        int height = rect.Bottom - rect.Top;
        if (!force && (width < 32 || height < 32 || width > 900 || height > 1100)) return;

        bool relatedToLine = IsWindowRelatedToLine(hWnd, parentHandle, processIds: ToArray(wanted));
        if (!force && !allowUnrelated && !relatedToLine) return;

        var className = new System.Text.StringBuilder(256);
        GetClassName(hWnd, className, className.Capacity);

        result.Add(new LineChatSummaryWindowInfo {
            Handle = hWnd, ProcessId = pid, ZOrder = zOrder, Left = rect.Left, Top = rect.Top,
            Width = width, Height = height, IsMinimized = false, IsVisible = true,
            RelatedToLine = relatedToLine,
            WindowClass = className.ToString(),
            UiaLeft = rect.Left, UiaTop = rect.Top, UiaScaleX = 1.0, UiaScaleY = 1.0
        });
    }

    private static int[] ToArray(HashSet<int> values) {
        var result = new int[values.Count];
        values.CopyTo(result);
        return result;
    }

    public static List<LineChatSummaryWindowInfo> GetPopupWindows(int[] processIds, IntPtr parentHandle) {
        var wanted = new HashSet<int>(processIds);
        var result = new List<LineChatSummaryWindowInfo>();
        var seen = new HashSet<IntPtr>();
        int zOrder = 0;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            int currentZOrder = zOrder++;
            AddPopupWindow(result, seen, hWnd, currentZOrder, wanted, parentHandle, false, false);
            return true;
        }, IntPtr.Zero);
        int childZOrder = -1;
        EnumChildWindows(parentHandle, delegate(IntPtr hWnd, IntPtr lParam) {
            AddPopupWindow(result, seen, hWnd, childZOrder--, wanted, parentHandle, false, false);
            return true;
        }, IntPtr.Zero);
        IntPtr lastActivePopup = GetLastActivePopup(parentHandle);
        if (lastActivePopup != parentHandle) {
            AddPopupWindow(result, seen, lastActivePopup, -2, wanted, parentHandle, true, false);
        }
        IntPtr enabledPopup = GetWindow(parentHandle, 6); // GW_ENABLEDPOPUP
        if (enabledPopup != parentHandle) {
            AddPopupWindow(result, seen, enabledPopup, -3, wanted, parentHandle, true, false);
        }
        IntPtr nativeMenu = FindWindow("#32768", null);
        AddPopupWindow(result, seen, nativeMenu, -4, wanted, parentHandle, false, false);
        // Some LINE builds show chat actions in a separate unowned utility window.
        // Inspect the foreground window semantically as a final popup candidate;
        // callers accept it only when the menu text and neighboring labels agree.
        IntPtr foreground = GetForegroundWindow();
        AddPopupWindow(result, seen, foreground, -5, wanted, parentHandle, false, true);
        return result;
    }

    public static IntPtr ForegroundWindow() {
        return GetForegroundWindow();
    }
    public static bool RenderWindow(IntPtr hWnd, IntPtr hdcBlt, uint flags) {
        return PrintWindow(hWnd, hdcBlt, flags);
    }
    public static bool ClickWindowClient(IntPtr hWnd, int x, int y) {
        const uint WM_LBUTTONDOWN = 0x0201;
        const uint WM_LBUTTONUP = 0x0202;
        const int MK_LBUTTON = 0x0001;
        int packedPoint = (y << 16) | (x & 0xffff);
        IntPtr point = new IntPtr(packedPoint);
        bool down = PostMessage(hWnd, WM_LBUTTONDOWN, new IntPtr(MK_LBUTTON), point);
        bool up = PostMessage(hWnd, WM_LBUTTONUP, IntPtr.Zero, point);
        return down && up;
    }
}
'@
}

$script:LogFolder = Join-Path $env:LOCALAPPDATA 'LineChatSummary\logs'
$script:LogPath = Join-Path $script:LogFolder ((Get-Date).ToString('yyyy-MM-dd') + '.log')
$script:GroupElements = @{}
$script:GroupOcrEngine = $null
$script:GroupOcrAwaiter = $null
$script:ManualTranscriptPath = $null
$script:LastSummaryPath = $null
$script:LastGroupScanSidebarFound = $false
$script:LastGroupScanIndividualWindowAttempted = $false

New-Item -ItemType Directory -Force -Path $script:LogFolder | Out-Null

function Write-AppLog {
    param([string]$Message, [string]$Level = 'INFO')
    # Intentionally log only workflow metadata, never chat contents, credentials, or prompts.
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
}

function Get-LineWindow {
    param([switch]$PreferForeground, [switch]$CurrentChat)
    $installRoot = Join-Path $env:LOCALAPPDATA 'LINE'
    $lineProcesses = New-Object System.Collections.Generic.List[object]
    foreach ($process in (Get-Process -ErrorAction SilentlyContinue)) {
        if ($process.ProcessName -match '^(LineCall|LineMediaPlayer)$') { continue }
        try {
            $processPath = $process.Path
            if ($processPath -and $processPath.StartsWith($installRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $lineProcesses.Add($process)
            }
        } catch { }
    }
    if ($lineProcesses.Count -eq 0) {
        foreach ($process in (Get-Process -Name 'LINE*' -ErrorAction SilentlyContinue)) {
            if ($process.ProcessName -notmatch '^(LineCall|LineMediaPlayer)$') { $lineProcesses.Add($process) }
        }
    }
    if ($lineProcesses.Count -eq 0) {
        throw '找不到 Windows LINE 程序。請先開啟並登入 LINE 桌面版。'
    }
    $pids = [int[]]@($lineProcesses | ForEach-Object { $_.Id })
    $windows = [LineChatSummaryNative]::GetWindows($pids)
    if ($windows.Count -eq 0) {
        Write-AppLog ('LineWindowDiscovery processes={0} topLevelWindows=0 session={1}' -f $lineProcesses.Count, [System.Diagnostics.Process]::GetCurrentProcess().SessionId) 'WARN'
        throw ('已找到 LINE 程序（{0} 個），但沒有可供輔助使用介面讀取的 LINE 視窗。請確認 LINE 已登入並保持執行。' -f $lineProcesses.Count)
    }
    $window = $null
    $rootElement = $null
    $selectionReason = 'largest'
    if ($CurrentChat) {
        $chatCandidates = New-Object System.Collections.Generic.List[object]
        foreach ($candidateWindow in ($windows | Where-Object { $_.IsVisible -and -not $_.IsMinimized })) {
            try {
                $candidateRoot = [System.Windows.Automation.AutomationElement]::FromHandle($candidateWindow.Handle)
                $candidateUiaBounds = $candidateRoot.Current.BoundingRectangle
                $candidateWindow.UiaScaleX = 1.0
                $candidateWindow.UiaScaleY = 1.0
                $candidateWindow.UiaLeft = [double]$candidateWindow.Left
                $candidateWindow.UiaTop = [double]$candidateWindow.Top
                if ($candidateUiaBounds.Width -gt 0 -and $candidateUiaBounds.Height -gt 0) {
                    $candidateScaleX = [double]$candidateUiaBounds.Width / [double]$candidateWindow.Width
                    $candidateScaleY = [double]$candidateUiaBounds.Height / [double]$candidateWindow.Height
                    if ($candidateScaleX -ge 0.5 -and $candidateScaleX -le 3.0) { $candidateWindow.UiaScaleX = $candidateScaleX }
                    if ($candidateScaleY -ge 0.5 -and $candidateScaleY -le 3.0) { $candidateWindow.UiaScaleY = $candidateScaleY }
                    $candidateWindow.UiaLeft = [double]$candidateUiaBounds.Left
                    $candidateWindow.UiaTop = [double]$candidateUiaBounds.Top
                }
                $candidateNodes = $candidateRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.Condition]::TrueCondition)
                $hasComposer = $false
                $hasWideHistory = $false
                $hasSidebar = $false
                foreach ($node in $candidateNodes) {
                    try {
                        $typeName = [string]$node.Current.ControlType.ProgrammaticName
                        $bounds = Convert-UiaBoundsToWindowPixels -Bounds $node.Current.BoundingRectangle -WindowInfo $candidateWindow
                        if ($typeName -eq 'ControlType.Edit' -and $bounds.Width -ge 100 -and $bounds.Top -ge [int]($candidateWindow.Height * 0.48)) {
                            $hasComposer = $true
                        }
                        if ($typeName -eq 'ControlType.List' -and $bounds.Height -ge [int]($candidateWindow.Height * 0.25)) {
                            if ($bounds.Width -ge [int]($candidateWindow.Width * 0.36)) { $hasWideHistory = $true }
                            elseif ($bounds.Left -lt [int]($candidateWindow.Width * 0.48) -and $bounds.Width -ge [int]($candidateWindow.Width * 0.18)) { $hasSidebar = $true }
                        }
                    } catch { }
                }
                $chatName = ''
                if ($hasComposer -or $hasWideHistory) {
                    try { $chatName = Get-LineActiveConversationName -WindowInfo $candidateWindow } catch { }
                }
                $hasConversation = ($hasComposer -and $hasWideHistory) -or
                    ($hasComposer -and -not [string]::IsNullOrWhiteSpace($chatName)) -or
                    ($hasWideHistory -and -not [string]::IsNullOrWhiteSpace($chatName))
                Write-AppLog ('CurrentChatWindowCandidate zOrder={0} visible={1} minimized={2} size={3}x{4} composer={5} history={6} sidebar={7} titleRead={8} accepted={9}' -f $candidateWindow.ZOrder, $candidateWindow.IsVisible, $candidateWindow.IsMinimized, $candidateWindow.Width, $candidateWindow.Height, $hasComposer, $hasWideHistory, $hasSidebar, (-not [string]::IsNullOrWhiteSpace($chatName)), $hasConversation) 'DEBUG'
                if ($hasConversation) {
                    $chatCandidates.Add([pscustomobject]@{
                        Window = $candidateWindow
                        Root = $candidateRoot
                        HasComposer = $hasComposer
                        HasHistory = $hasWideHistory
                        HasSidebar = $hasSidebar
                        Name = $chatName
                    })
                }
            } catch {
                Write-AppLog ('CurrentChatWindowProbeFailed zOrder={0} category={1}' -f $candidateWindow.ZOrder, $_.Exception.GetType().Name) 'DEBUG'
            }
        }
        if ($chatCandidates.Count -eq 0) {
            Write-AppLog ('CurrentChatWindowDiscovery candidates=0 topLevelWindows={0}' -f $windows.Count) 'WARN'
            throw '找不到已開啟的 LINE 聊天室視窗。請在 LINE 開啟目標聊天室並保持視窗顯示，再按「重新偵測」。工具不會切換視窗或移動滑鼠。'
        }
        $dedicatedCandidates = @($chatCandidates | Where-Object { -not $_.HasSidebar -and $_.HasComposer -and $_.HasHistory })
        if ($dedicatedCandidates.Count -gt 0) {
            $selectedCandidate = $dedicatedCandidates | Sort-Object { $_.Window.ZOrder } | Select-Object -First 1
            $selectionReason = 'current-chat-dedicated-window'
        } else {
            $selectedCandidate = $chatCandidates | Sort-Object { $_.Window.ZOrder } | Select-Object -First 1
            $selectionReason = 'current-chat-visible-window'
        }
        $window = $selectedCandidate.Window
        $rootElement = $selectedCandidate.Root
        $script:LastCurrentChatName = [string]$selectedCandidate.Name
        Write-AppLog ('CurrentChatWindowDiscovery candidates={0} dedicated={1} selectedZOrder={2} selection={3} titleRead={4}' -f $chatCandidates.Count, $dedicatedCandidates.Count, $window.ZOrder, $selectionReason, (-not [string]::IsNullOrWhiteSpace($script:LastCurrentChatName)))
    } elseif ($PreferForeground) {
        $foreground = [LineChatSummaryNative]::ForegroundWindow()
        $window = $windows | Where-Object { $_.Handle -eq $foreground } | Select-Object -First 1
        if ($null -ne $window) { $selectionReason = 'foreground' }
    }
    if ($null -eq $window) {
        $window = $windows | Sort-Object -Property @{ Expression = { $_.IsVisible }; Descending = $true }, @{ Expression = { $_.Width * $_.Height }; Descending = $true } | Select-Object -First 1
    }
    if ($null -eq $rootElement) { $rootElement = [System.Windows.Automation.AutomationElement]::FromHandle($window.Handle) }
    $uiaBounds = $null
    $window.UiaScaleX = 1.0
    $window.UiaScaleY = 1.0
    $window.UiaLeft = [double]$window.Left
    $window.UiaTop = [double]$window.Top
    try {
        $uiaBounds = $rootElement.Current.BoundingRectangle
        if ($uiaBounds.Width -gt 0 -and $uiaBounds.Height -gt 0) {
            $scaleX = [double]$uiaBounds.Width / [double]$window.Width
            $scaleY = [double]$uiaBounds.Height / [double]$window.Height
            if ($scaleX -ge 0.5 -and $scaleX -le 3.0) { $window.UiaScaleX = $scaleX }
            if ($scaleY -ge 0.5 -and $scaleY -le 3.0) { $window.UiaScaleY = $scaleY }
            $window.UiaLeft = [double]$uiaBounds.Left
            $window.UiaTop = [double]$uiaBounds.Top
        }
    } catch { }
    $uiaRectLog = 'unavailable'
    if ($null -ne $uiaBounds -and $uiaBounds.Width -gt 0 -and $uiaBounds.Height -gt 0) {
        $uiaRectLog = '{0},{1},{2},{3}' -f [int]$uiaBounds.Left, [int]$uiaBounds.Top, [int]$uiaBounds.Width, [int]$uiaBounds.Height
    }
    Write-AppLog ('LineWindowDiscovery processes={0} topLevelWindows={1} selectedPid={2} zOrder={3} bounds={4},{5},{6},{7} uiaBounds={8} uiaScale={9:N3},{10:N3} visible={11} minimized={12} selection={13}' -f $lineProcesses.Count, $windows.Count, $window.ProcessId, $window.ZOrder, $window.Left, $window.Top, $window.Width, $window.Height, $uiaRectLog, $window.UiaScaleX, $window.UiaScaleY, $window.IsVisible, $window.IsMinimized, $selectionReason)
    return [pscustomobject]@{
        Info = $window
        Element = $rootElement
    }
}

function Convert-UiaBoundsToWindowPixels {
    param([object]$Bounds, [LineChatSummaryWindowInfo]$WindowInfo)
    $scaleX = [double]$WindowInfo.UiaScaleX
    $scaleY = [double]$WindowInfo.UiaScaleY
    if ($scaleX -lt 0.5 -or $scaleX -gt 3.0) { $scaleX = 1.0 }
    if ($scaleY -lt 0.5 -or $scaleY -gt 3.0) { $scaleY = 1.0 }
    return [pscustomobject]@{
        Left = [double]($Bounds.Left - $WindowInfo.UiaLeft) / $scaleX
        Top = [double]($Bounds.Top - $WindowInfo.UiaTop) / $scaleY
        Right = [double]($Bounds.Right - $WindowInfo.UiaLeft) / $scaleX
        Bottom = [double]($Bounds.Bottom - $WindowInfo.UiaTop) / $scaleY
        Width = [double]$Bounds.Width / $scaleX
        Height = [double]$Bounds.Height / $scaleY
    }
}

function Get-LineWindowCapture {
    param([LineChatSummaryWindowInfo]$WindowInfo)
    $bitmap = New-Object System.Drawing.Bitmap([int]$WindowInfo.Width, [int]$WindowInfo.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $hdc = [IntPtr]::Zero
    $rendered = $false
    $renderedClient = $false
    $renderedFallback = $false
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $hdc = $graphics.GetHdc()
        $renderedClient = [LineChatSummaryNative]::RenderWindow($WindowInfo.Handle, $hdc, 2)
        $rendered = $renderedClient
        if (-not $rendered) {
            $renderedFallback = [LineChatSummaryNative]::RenderWindow($WindowInfo.Handle, $hdc, 0)
            $rendered = $renderedFallback
        }
    } catch {
        $timer.Stop()
        Write-AppLog ('LineWindowCapture failed exception={0} size={1}x{2} visible={3} minimized={4} elapsedMs={5}' -f $_.Exception.GetType().Name, $WindowInfo.Width, $WindowInfo.Height, $WindowInfo.IsVisible, $WindowInfo.IsMinimized, $timer.ElapsedMilliseconds) 'WARN'
        $bitmap.Dispose()
        throw
    } finally {
        if ($hdc -ne [IntPtr]::Zero) { $graphics.ReleaseHdc($hdc) }
        $graphics.Dispose()
    }
    $timer.Stop()
    Write-AppLog ('LineWindowCapture rendered={0} flags2={1} flags0={2} size={3}x{4} visible={5} minimized={6} elapsedMs={7}' -f $rendered, $renderedClient, $renderedFallback, $WindowInfo.Width, $WindowInfo.Height, $WindowInfo.IsVisible, $WindowInfo.IsMinimized, $timer.ElapsedMilliseconds) $(if ($rendered) { 'DEBUG' } else { 'WARN' })
    if (-not $rendered) {
        $bitmap.Dispose()
        throw 'LINE 未能提供背景視窗影像；未切換前景或擷取桌面滑鼠畫面。'
    }
    return $bitmap
}

function Invoke-LineWinRtAsync {
    param([object]$Operation, [type]$ResultType)
    if ($null -eq $script:GroupOcrAwaiter) {
        throw 'Windows OCR asynchronous runtime is not initialized.'
    }
    return $script:GroupOcrAwaiter.MakeGenericMethod($ResultType).Invoke($null, @($Operation)).GetResult()
}

function Initialize-LineGroupOcr {
    if ($null -ne $script:GroupOcrEngine) { return $script:GroupOcrEngine }
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType=WindowsRuntime]
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType=WindowsRuntime]
    $null = [Windows.Storage.Streams.RandomAccessStream, Windows.Storage.Streams, ContentType=WindowsRuntime]
    $null = [Windows.Foundation.IAsyncOperation`1, Windows.Foundation, ContentType=WindowsRuntime]
    $script:GroupOcrAwaiter = [WindowsRuntimeSystemExtensions].GetMember('GetAwaiter', 'Method', 'Public,Static') |
        Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } |
        Select-Object -First 1
    if ($null -eq $script:GroupOcrAwaiter) { throw 'Windows OCR asynchronous runtime is unavailable.' }
    $languages = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages)
    $language = $languages | Where-Object { $_.LanguageTag -like 'zh-Hant*' } | Select-Object -First 1
    if ($null -eq $language) { $language = $languages | Where-Object { $_.LanguageTag -like 'zh-Hans*' } | Select-Object -First 1 }
    if ($null -ne $language) { $script:GroupOcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($language) }
    if ($null -eq $script:GroupOcrEngine) { $script:GroupOcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
    if ($null -eq $script:GroupOcrEngine) { throw '未安裝可用的 Windows OCR 語言辨識元件。' }
    return $script:GroupOcrEngine
}

function Get-LineGroupNamesByOcr {
    param([object[]]$Rows, [LineChatSummaryWindowInfo]$WindowInfo)
    if ($Rows.Count -eq 0) { return ,@() }
    $engine = Initialize-LineGroupOcr
    # PrintWindow renders the LINE HWND into memory without focusing it or using the desktop cursor.
    $cropHeight = 40
    $scale = 2
    $gap = 12
    $entries = New-Object System.Collections.Generic.List[object]
    $maxWidth = 0
    foreach ($row in ($Rows | Sort-Object Top)) {
        $bounds = Convert-UiaBoundsToWindowPixels -Bounds $row.Bounds -WindowInfo $WindowInfo
        if ($bounds.Right -lt 0 -or $bounds.Left -gt $WindowInfo.Width) { continue }
        $left = [Math]::Max(0, [int][Math]::Floor($bounds.Left))
        $top = [Math]::Max(0, [int][Math]::Floor($bounds.Top))
        $right = [Math]::Min($WindowInfo.Width, [int][Math]::Ceiling($bounds.Right))
        $bottom = [Math]::Min($WindowInfo.Height, [int][Math]::Floor($bounds.Top + [Math]::Min($cropHeight, $bounds.Height)))
        $width = $right - $left
        $height = $bottom - $top
        if ($width -lt 100 -or $height -lt 16) { continue }
        $entry = [pscustomobject]@{
            Row = $row
            Source = (New-Object System.Drawing.Rectangle($left, $top, $width, $height))
            TileTop = ($entries.Count * (($cropHeight * $scale) + $gap))
            TileHeight = ($height * $scale)
        }
        $entries.Add($entry)
        $maxWidth = [Math]::Max($maxWidth, $width * $scale)
    }
    if ($entries.Count -eq 0) { throw '聊天室清單列不在目前可擷取的螢幕範圍內。' }
    $tileStep = ($cropHeight * $scale) + $gap
    $montage = New-Object System.Drawing.Bitmap($maxWidth, ($entries.Count * $tileStep))
    $canvas = [System.Drawing.Graphics]::FromImage($montage)
    $canvas.Clear([System.Drawing.Color]::White)
    $canvas.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $windowCapture = $null
    try {
        $windowCapture = Get-LineWindowCapture -WindowInfo $WindowInfo
        foreach ($entry in $entries) {
            $rowImage = $windowCapture.Clone($entry.Source, $windowCapture.PixelFormat)
            try {
                $canvas.DrawImage($rowImage, (New-Object System.Drawing.Rectangle(0, $entry.TileTop, ($entry.Source.Width * $scale), $entry.TileHeight)))
            } finally {
                $rowImage.Dispose()
            }
        }
        $tempImage = Join-Path ([System.IO.Path]::GetTempPath()) ('LineChatSummary-OCR-{0}.png' -f [guid]::NewGuid().ToString('N'))
        try {
            $montage.Save($tempImage, [System.Drawing.Imaging.ImageFormat]::Png)
            $file = Invoke-LineWinRtAsync ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tempImage)) ([Windows.Storage.StorageFile])
            $stream = Invoke-LineWinRtAsync ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
            $decoder = Invoke-LineWinRtAsync ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
            $softwareBitmap = Invoke-LineWinRtAsync ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
            $ocrResult = Invoke-LineWinRtAsync ($engine.RecognizeAsync($softwareBitmap)) ([Windows.Media.Ocr.OcrResult])
            $textByTile = @{}
            foreach ($line in $ocrResult.Lines) {
                $bounds = $line.BoundingRect
                $tileIndex = [int][Math]::Floor(([double]$bounds.Y + ([double]$bounds.Height / 2)) / $tileStep)
                if ($tileIndex -lt 0 -or $tileIndex -ge $entries.Count) { continue }
                $name = ([string]$line.Text).Trim()
                $name = [regex]::Replace($name, '\s+\d{1,2}:\d{2}\s*$', '').Trim()
                if ($name.Length -lt 1 -or $name.Length -gt 70 -or $name -match '^\d{1,2}:\d{2}$') { continue }
                if (-not $textByTile.ContainsKey($tileIndex) -or $name.Length -gt $textByTile[$tileIndex].Length) {
                    $textByTile[$tileIndex] = $name
                }
            }
            $detected = New-Object System.Collections.Generic.List[object]
            foreach ($tileIndex in ($textByTile.Keys | Sort-Object)) {
                $entry = $entries[$tileIndex]
                $name = [string]$textByTile[$tileIndex]
                if ($name -match '^(聊天|聊天室|好友|首頁|主頁|設定|通知|搜尋|Chats|Friends|Home|Settings)$') { continue }
                $detected.Add([pscustomobject]@{ Name = $name; Element = $entry.Row.Element; Top = [double]$entry.Row.Top; Width = [double]$entry.Row.Bounds.Width })
            }
            Write-AppLog ('GroupScanOcrCompleted language={0} rows={1} textLines={2} names={3}' -f $engine.RecognizerLanguage.LanguageTag, $entries.Count, $ocrResult.Lines.Count, $detected.Count)
            return ,$detected.ToArray()
        } finally {
            try { if ($null -ne $softwareBitmap) { $softwareBitmap.Dispose() } } catch { }
            try { if ($null -ne $stream) { $stream.Close() } } catch { }
            try { if ($null -ne $stream) { $stream.Dispose() } } catch { }
            try { if ($null -ne $decoder) { $decoder.Dispose() } } catch { }
            if (Test-Path -LiteralPath $tempImage) { Remove-Item -LiteralPath $tempImage -Force -ErrorAction SilentlyContinue }
        }
    } finally {
        $canvas.Dispose()
        $montage.Dispose()
        if ($null -ne $windowCapture) { $windowCapture.Dispose() }
    }
}

function Get-LineActiveConversationName {
    param([LineChatSummaryWindowInfo]$WindowInfo)
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($WindowInfo.Handle)
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    $includeOffscreen = (-not $WindowInfo.IsVisible -or $WindowInfo.IsMinimized)
    $headerTop = 36
    $headerBottom = 125
    $headerLeft = [int]($WindowInfo.Width * 0.25)
    $headerRight = [int]($WindowInfo.Width * 0.78)
    $headerNames = New-Object System.Collections.Generic.List[object]
    foreach ($element in $all) {
        try {
            if (@('ControlType.Text', 'ControlType.Custom', 'ControlType.Group', 'ControlType.Button') -notcontains $element.Current.ControlType.ProgrammaticName) { continue }
            if ($element.Current.IsOffscreen -and -not $includeOffscreen) { continue }
            $bounds = Convert-UiaBoundsToWindowPixels -Bounds $element.Current.BoundingRectangle -WindowInfo $WindowInfo
            if ($bounds.Top -lt $headerTop -or $bounds.Bottom -gt $headerBottom -or
                $bounds.Left -lt $headerLeft -or $bounds.Left -gt $headerRight -or
                $bounds.Width -lt 16 -or $bounds.Height -lt 10) { continue }
            $name = Get-ElementAccessibleLabel -Element $element
            if ($name.Length -lt 2 -or $name.Length -gt 70 -or $name -match '^\(?\d{1,4}\)?$') { continue }
            if ($name -match '^(LINE|LINE\s+WORKS|聊天|聊天室|搜尋|搜索|更多|Search|More|Options)$') { continue }
            $headerNames.Add([pscustomobject]@{ Name = $name; Top = [double]$bounds.Top; Left = [double]$bounds.Left })
        } catch { }
    }
    if ($headerNames.Count -gt 0) {
        $name = [string](($headerNames | Sort-Object Top, Left | Select-Object -First 1).Name)
        Write-AppLog ('IndividualChatTitleUiA found=True candidates={0}' -f $headerNames.Count)
        return $name
    }
    if (-not $WindowInfo.IsVisible -or $WindowInfo.IsMinimized) {
        Write-AppLog ('IndividualChatTitleOcrSkipped visible={0} minimized={1} reason=window-not-rendered' -f $WindowInfo.IsVisible, $WindowInfo.IsMinimized) 'WARN'
        return ''
    }
    $engine = Initialize-LineGroupOcr
    $left = 44
    $top = 58
    $width = [Math]::Min(460, $WindowInfo.Width - $left - 12)
    $height = [Math]::Min(62, $WindowInfo.Height - $top - 12)
    if ($width -lt 160 -or $height -lt 28) { return '' }
    $scale = 2
    $capture = New-Object System.Drawing.Bitmap(($width * $scale), ($height * $scale))
    $graphics = [System.Drawing.Graphics]::FromImage($capture)
    $windowCapture = $null
    $stream = $null
    $decoder = $null
    $softwareBitmap = $null
    $tempImage = $null
    try {
        $windowCapture = Get-LineWindowCapture -WindowInfo $WindowInfo
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $destination = New-Object System.Drawing.Rectangle(0, 0, ($width * $scale), ($height * $scale))
        $source = New-Object System.Drawing.Rectangle($left, $top, $width, $height)
        $graphics.DrawImage($windowCapture, $destination, $source, [System.Drawing.GraphicsUnit]::Pixel)
        $tempImage = Join-Path ([System.IO.Path]::GetTempPath()) ('LineChatSummary-Header-{0}.png' -f [guid]::NewGuid().ToString('N'))
        $capture.Save($tempImage, [System.Drawing.Imaging.ImageFormat]::Png)
        $file = Invoke-LineWinRtAsync ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tempImage)) ([Windows.Storage.StorageFile])
        $stream = Invoke-LineWinRtAsync ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        $decoder = Invoke-LineWinRtAsync ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $softwareBitmap = Invoke-LineWinRtAsync ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $ocrResult = Invoke-LineWinRtAsync ($engine.RecognizeAsync($softwareBitmap)) ([Windows.Media.Ocr.OcrResult])
        $recognized = New-Object System.Collections.Generic.List[object]
        foreach ($line in $ocrResult.Lines) {
            $name = ([string]$line.Text).Trim()
            $name = [regex]::Replace($name, '\s+\d{1,2}:\d{2}\s*$', '').Trim()
            if ($name.Length -lt 2 -or $name.Length -gt 70) { continue }
            if ($name -match '^(LINE|LINE\s+WORKS|聊天|聊天室|好友|搜尋|搜索|Chats|Friends|Search|Home|Settings)$') { continue }
            if ($name -notmatch '[\p{L}\p{N}]') { continue }
            $recognized.Add([pscustomobject]@{ Name = $name; Top = [double]$line.BoundingRect.Y; Left = [double]$line.BoundingRect.X })
        }
        $name = ''
        if ($recognized.Count -gt 0) { $name = [string](($recognized | Sort-Object Top, Left | Select-Object -First 1).Name) }
        Write-AppLog ('IndividualChatTitleOcr language={0} lines={1} candidates={2} found={3}' -f $engine.RecognizerLanguage.LanguageTag, $ocrResult.Lines.Count, $recognized.Count, (-not [string]::IsNullOrWhiteSpace($name)))
        return $name
    } finally {
        try { if ($null -ne $softwareBitmap) { $softwareBitmap.Dispose() } } catch { }
        try { if ($null -ne $stream) { $stream.Close() } } catch { }
        try { if ($null -ne $stream) { $stream.Dispose() } } catch { }
        try { if ($null -ne $decoder) { $decoder.Dispose() } } catch { }
        try { $graphics.Dispose() } catch { }
        try { $capture.Dispose() } catch { }
        if ($null -ne $windowCapture) { $windowCapture.Dispose() }
        if ($tempImage -and (Test-Path -LiteralPath $tempImage)) { Remove-Item -LiteralPath $tempImage -Force -ErrorAction SilentlyContinue }
    }
}

function Get-ElementAccessibleLabel {
    param([System.Windows.Automation.AutomationElement]$Element)
    try {
        $name = ([string]$Element.Current.Name).Trim()
        if (-not [string]::IsNullOrWhiteSpace($name)) { return $name }
    } catch { }
    try {
        $pattern = $Element.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern)
        $name = ([string]$pattern.Current.Name).Trim()
        if (-not [string]::IsNullOrWhiteSpace($name)) { return $name }
    } catch { }
    try {
        $pattern = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        $name = ([string]$pattern.Current.Value).Trim()
        if (-not [string]::IsNullOrWhiteSpace($name)) { return $name }
    } catch { }
    try {
        $pattern = $Element.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
        $text = [string]$pattern.DocumentRange.GetText(300)
        $name = @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)[0]
        if (-not [string]::IsNullOrWhiteSpace($name)) { return ([string]$name).Trim() }
    } catch { }
    return ''
}

function Get-RowDisplayName {
    param([System.Windows.Automation.AutomationElement]$Element, [bool]$AllowOffscreen = $false)
    $rowBounds = $Element.Current.BoundingRectangle
    try {
        $descendants = $Element.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition)
        $textNodes = New-Object System.Collections.Generic.List[object]
        for ($index = 0; $index -lt $descendants.Count; $index++) {
            $child = $descendants.Item($index)
            try {
                if (@('ControlType.Text', 'ControlType.Group', 'ControlType.Custom', 'ControlType.Button') -notcontains $child.Current.ControlType.ProgrammaticName) { continue }
                if ($child.Current.IsOffscreen -and -not $AllowOffscreen) { continue }
                $bounds = $child.Current.BoundingRectangle
                if ($bounds.Left -lt $rowBounds.Left -or $bounds.Right -gt $rowBounds.Right + 6) { continue }
                if ($bounds.Top -lt $rowBounds.Top -or $bounds.Top -gt $rowBounds.Top + 38) { continue }
                $name = Get-ElementAccessibleLabel -Element $child
                if ($name.Length -gt 0 -and $name.Length -le 70) {
                    $textNodes.Add([pscustomobject]@{ Name = $name; Top = [double]$bounds.Top; Left = [double]$bounds.Left })
                }
            } catch { }
        }
        if ($textNodes.Count -gt 0) {
            return [string](($textNodes | Sort-Object Top, Left | Select-Object -First 1).Name)
        }
    } catch { }
    return Get-ElementAccessibleLabel -Element $Element
}

function Get-GroupElements {
    $line = Get-LineWindow
    $root = $line.Element
    $win = $line.Info
    $includeOffscreen = (-not $win.IsVisible -or $win.IsMinimized)
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    $script:LastGroupScanElementCount = $all.Count
    $candidates = New-Object System.Collections.Generic.List[object]
    $ocrRows = New-Object System.Collections.Generic.List[object]
    $seenOcrRows = @{}
    $acceptedTypes = @('ControlType.ListItem', 'ControlType.TreeItem', 'ControlType.DataItem', 'ControlType.Custom', 'ControlType.Group', 'ControlType.Button')
    $leftMin = [int]($win.Width * 0.025)
    # Default to the left sidebar, then replace these bounds when UIA exposes its
    # actual List control. LINE layouts vary substantially with window size.
    $leftMax = [int]($win.Width * 0.55)
    $topMin = 55
    $bottomMax = $win.Height - 55
    $sidebarLists = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $all.Count; $i++) {
        $element = $all.Item($i)
        try {
            if ($element.Current.ControlType.ProgrammaticName -ne 'ControlType.List' -or ($element.Current.IsOffscreen -and -not $includeOffscreen)) { continue }
            $bounds = Convert-UiaBoundsToWindowPixels -Bounds $element.Current.BoundingRectangle -WindowInfo $win
            $relativeLeft = $bounds.Left
            if ($bounds.Width -lt 180 -or $bounds.Height -lt [Math]::Max(160, [int]($win.Height * 0.30))) { continue }
            if ($relativeLeft -gt [int]($win.Width * 0.70) -or $bounds.Right -gt ($win.Width + 8)) { continue }
            $sidebarLists.Add([pscustomobject]@{ Element = $element; Bounds = $bounds; Left = [double]$bounds.Left })
        } catch { }
    }
    $sidebarListFound = $sidebarLists.Count -gt 0
    $script:LastGroupScanSidebarFound = $sidebarListFound
    $script:LastGroupScanIndividualWindowAttempted = $false
    $sidebarBounds = $null
    if ($sidebarListFound) {
        $sidebar = $sidebarLists | Sort-Object Left | Select-Object -First 1
        $sidebarBounds = $sidebar.Bounds
        $leftMin = [Math]::Max($leftMin, [int]$sidebarBounds.Left)
        $leftMax = [Math]::Min([int]($win.Width * 0.90), [int]$sidebarBounds.Right + 4)
        $topMin = [Math]::Max(45, [int]$sidebarBounds.Top - 2)
        $bottomMax = [Math]::Min(($win.Height - 8), [int]$sidebarBounds.Bottom + 2)
    }
    for ($i = 0; $i -lt $all.Count; $i++) {
        $element = $all.Item($i)
        try {
            if ($acceptedTypes -notcontains $element.Current.ControlType.ProgrammaticName) { continue }
            if ($element.Current.IsOffscreen -and -not $includeOffscreen) { continue }
            $uiaRect = $element.Current.BoundingRectangle
            $bounds = Convert-UiaBoundsToWindowPixels -Bounds $uiaRect -WindowInfo $win
            if ($bounds.Width -lt 115 -or $bounds.Height -lt 24 -or $bounds.Height -gt 105) { continue }
            if ($bounds.Left -lt $leftMin -or $bounds.Right -gt $leftMax) { continue }
            if ($bounds.Top -lt $topMin -or $bounds.Top -gt $bottomMax) { continue }
            $name = Get-RowDisplayName -Element $element -AllowOffscreen:$includeOffscreen
            if ($name.Length -gt 70) { $name = '' }
            if ([string]::IsNullOrWhiteSpace($name)) {
                $typeName = [string]$element.Current.ControlType.ProgrammaticName
                if ($typeName -in @('ControlType.ListItem', 'ControlType.TreeItem', 'ControlType.DataItem')) {
                    $ocrKey = [int]([math]::Round($bounds.Top / 12))
                    if (-not $seenOcrRows.ContainsKey($ocrKey)) {
                        $seenOcrRows[$ocrKey] = $true
                        $ocrRows.Add([pscustomobject]@{ Element = $element; Top = [double]$bounds.Top; Bounds = $uiaRect })
                    }
                }
                continue
            }
            if ($name -match '^(聊天|聊天室|好友|首頁|主頁|設定|通知|搜尋|Chats|Friends|Home|Settings)$') { continue }
            $candidates.Add([pscustomobject]@{ Name = $name; Element = $element; Top = [double]$bounds.Top; Width = [double]$bounds.Width })
        } catch {
            continue
        }
    }
    if ($ocrRows.Count -gt 0) {
        if (-not $win.IsVisible -or $win.IsMinimized) {
            Write-AppLog ('GroupScanOcrSkipped rows={0} visible={1} minimized={2} reason=window-not-rendered' -f $ocrRows.Count, $win.IsVisible, $win.IsMinimized) 'WARN'
        } else {
            try {
                $ocrCandidates = Get-LineGroupNamesByOcr -Rows $ocrRows.ToArray() -WindowInfo $win
                foreach ($candidate in $ocrCandidates) { $candidates.Add($candidate) }
            } catch {
                Write-AppLog ('GroupScanOcrFailed category={0}' -f $_.Exception.GetType().Name) 'WARN'
            }
        }
    }
    # Some LINE builds expose chat rows only as text. Always merge this fallback with
    # row controls because a partially exposed UIA tree may contain both kinds.
    $textCandidates = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $all.Count; $i++) {
        $element = $all.Item($i)
        try {
            if ($element.Current.ControlType.ProgrammaticName -ne 'ControlType.Text') { continue }
            if ($element.Current.IsOffscreen -and -not $includeOffscreen) { continue }
            $bounds = Convert-UiaBoundsToWindowPixels -Bounds $element.Current.BoundingRectangle -WindowInfo $win
            if ($bounds.Left -lt 45 -or $bounds.Right -gt $leftMax) { continue }
            if ($bounds.Top -lt $topMin -or $bounds.Top -gt $bottomMax -or $bounds.Height -lt 12 -or $bounds.Height -gt 30) { continue }
            $name = ([string]$element.Current.Name).Trim()
            if ($name.Length -lt 2 -or $name.Length -gt 70 -or $name -match '^\d{1,2}:\d{2}$') { continue }
            $textCandidates.Add([pscustomobject]@{ Name = $name; Element = $element; Top = [double]$bounds.Top; Left = [double]$bounds.Left })
        } catch { }
    }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($item in ($textCandidates | Sort-Object Top, Left)) {
        if ($rows.Count -eq 0 -or [math]::Abs($item.Top - $rows[$rows.Count - 1].Top) -gt 28) {
            $rows.Add([pscustomobject]@{ Top = $item.Top; Items = (New-Object System.Collections.Generic.List[object]) })
        }
        $rows[$rows.Count - 1].Items.Add($item)
    }
    foreach ($row in $rows) {
        $first = $row.Items | Sort-Object Left | Select-Object -First 1
        if ($first -and $first.Name -notmatch '^(聊天|聊天室|好友|首頁|主頁|設定|通知|搜尋|Chats|Friends|Home|Settings)$') {
            $candidates.Add([pscustomobject]@{ Name = $first.Name; Element = $first.Element; Top = $row.Top; Width = 0 })
        }
    }
    $result = @{}
    $counts = @{}
    $seenRows = @{}
    foreach ($candidate in ($candidates | Sort-Object Top, Name, @{Expression={ $_.Width };Descending=$true})) {
        $baseName = $candidate.Name
        $rowKey = '{0}|{1}' -f $baseName, [int]([math]::Round($candidate.Top / 12))
        if ($seenRows.ContainsKey($rowKey)) { continue }
        $seenRows[$rowKey] = $true
        if (-not $counts.ContainsKey($baseName)) { $counts[$baseName] = 0 }
        $counts[$baseName]++
        $displayName = $baseName
        if ($counts[$baseName] -gt 1) { $displayName = '{0} ({1})' -f $baseName, $counts[$baseName] }
        $result[$displayName] = [pscustomobject]@{ Name = $baseName; Element = $candidate.Element }
    }
    if ($result.Count -eq 0 -and -not $sidebarListFound) {
        $hasChatComposer = $false
        $hasWideHistoryList = $false
        for ($i = 0; $i -lt $all.Count; $i++) {
            $element = $all.Item($i)
            try {
                $typeName = [string]$element.Current.ControlType.ProgrammaticName
                $bounds = Convert-UiaBoundsToWindowPixels -Bounds $element.Current.BoundingRectangle -WindowInfo $win
                if ($typeName -eq 'ControlType.Edit' -and $bounds.Width -ge 100 -and $bounds.Top -ge [int]($win.Height * 0.55)) { $hasChatComposer = $true }
                if ($typeName -eq 'ControlType.List' -and $bounds.Width -ge [int]($win.Width * 0.45) -and $bounds.Height -ge [int]($win.Height * 0.30)) { $hasWideHistoryList = $true }
            } catch { }
        }
        $script:LastGroupScanIndividualWindowAttempted = ($hasChatComposer -or $hasWideHistoryList)
        if ($hasChatComposer -or $hasWideHistoryList) {
            try {
                $conversationName = Get-LineActiveConversationName -WindowInfo $win
                if (-not [string]::IsNullOrWhiteSpace($conversationName)) {
                    $displayName = '目前聊天室：' + $conversationName
                    $result[$displayName] = [pscustomobject]@{ Name = $conversationName; Element = $root; CurrentConversation = $true; Line = $line }
                }
            } catch {
                Write-AppLog ('IndividualChatTitleOcrFailed category={0}' -f $_.Exception.GetType().Name) 'WARN'
                Write-AppLog 'IndividualChatTitleReadFailed' 'WARN'
            }
        }
        Write-AppLog ('IndividualChatFallback chatComposer={0} wideHistoryList={1} candidateFound={2}' -f $hasChatComposer, $hasWideHistoryList, ($result.Count -gt 0))
    }
    $script:LastGroupScanAccessibleCount = $result.Count
    $sidebarGeometry = 'none'
    if ($sidebarListFound) { $sidebarGeometry = '{0},{1},{2},{3}' -f [int]$sidebarBounds.Left, [int]$sidebarBounds.Top, [int]$sidebarBounds.Width, [int]$sidebarBounds.Height }
    Write-AppLog ('GroupScanGeometry pid={0} windowWidth={1} uiaScale={2:N3},{3:N3} rowRightLimit={4} sidebar={5} descendants={6} candidates={7} result={8}' -f $win.ProcessId, $win.Width, $win.UiaScaleX, $win.UiaScaleY, [int]$leftMax, $sidebarGeometry, $all.Count, $candidates.Count, $result.Count)
    if ($result.Count -eq 0) {
        if ($win.IsMinimized -or -not $win.IsVisible) {
            $windowState = '已縮小'
            if (-not $win.IsVisible -and -not $win.IsMinimized) { $windowState = '未顯示' }
            Write-AppLog ('GroupScanUnavailable state={0} uiaDescendants={1} rows={2} reason=unreadable-background-content' -f $windowState, $all.Count, $ocrRows.Count) 'WARN'
            throw ('LINE 視窗{0}時沒有提供可讀取的聊天室名稱或背景畫面，因此無法辨識群組。請還原 LINE 後重新掃描。工具未切換前景或移動滑鼠。' -f $windowState)
        }
        Write-AppLog ('GroupScanTreeSummary pid={0} window={1},{2},{3},{4} descendants={5} currentSession={6}' -f $win.ProcessId, $win.Left, $win.Top, $win.Width, $win.Height, $all.Count, [System.Diagnostics.Process]::GetCurrentProcess().SessionId) 'WARN'
        $typeCounts = @{}
        $nodeCount = [math]::Min($all.Count, 180)
        for ($index = 0; $index -lt $nodeCount; $index++) {
            $node = $all.Item($index)
            try {
                $currentNode = $node.Current
                $typeName = [string]$currentNode.ControlType.ProgrammaticName
                if (-not $typeCounts.ContainsKey($typeName)) { $typeCounts[$typeName] = 0 }
                $typeCounts[$typeName]++
                $rect = Convert-UiaBoundsToWindowPixels -Bounds $currentNode.BoundingRectangle -WindowInfo $win
                $nameLength = ([string]$currentNode.Name).Length
                Write-AppLog ('GroupScanNode n={0} type={1} rel={2},{3} size={4}x{5} offscreen={6} nameChars={7} pid={8}' -f $index, $typeName, [int]$rect.Left, [int]$rect.Top, [int]$rect.Width, [int]$rect.Height, $currentNode.IsOffscreen, $nameLength, $currentNode.ProcessId) 'DEBUG'
            } catch {
                Write-AppLog ('GroupScanNode n={0} propertyReadFailed={1}' -f $index, $_.Exception.GetType().Name) 'DEBUG'
            }
        }
        foreach ($typeName in ($typeCounts.Keys | Sort-Object)) {
            Write-AppLog ('GroupScanControlType type={0} count={1}' -f $typeName, $typeCounts[$typeName]) 'DEBUG'
        }
        if ($all.Count -gt $nodeCount) { Write-AppLog ('GroupScanNodeLimit total={0} logged={1}' -f $all.Count, $nodeCount) 'DEBUG' }
    }
    return $result
}

function Get-DescendantsByProcess {
    param([System.Windows.Automation.AutomationElement]$Root, [int]$ProcessId)
    # Menus in LINE can be separate top-level popup windows, so search the desktop
    # automation tree and filter by LINE's process instead of limiting to one HWND.
    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $ProcessId)
    $all = $desktop.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
    $found = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $all.Count; $i++) { $found.Add($all.Item($i)) }
    return ,$found.ToArray()
}

function ConvertTo-LineUiaDiagnosticToken {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    if ($Value -match '^[A-Za-z0-9_.:-]{1,48}$') { return $Value }
    return ('nonAsciiOrLong{0}' -f $Value.Length)
}

function Get-LineUiaStructureSignature {
    param([System.Windows.Automation.AutomationElement]$Element)
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $path = New-Object System.Collections.Generic.List[string]
    $node = $Element
    for ($depth = 0; $depth -lt 8 -and $null -ne $node; $depth++) {
        try {
            $current = $node.Current
            $className = ConvertTo-LineUiaDiagnosticToken ([string]$current.ClassName)
            $automationId = ConvertTo-LineUiaDiagnosticToken ([string]$current.AutomationId)
            $typeName = [string]$current.ControlType.ProgrammaticName
            $path.Add(('{0}/{1}{2}' -f $typeName, $className, $(if ($automationId) { '[id=' + $automationId + ']' } else { '' })))
            $node = $walker.GetParent($node)
        } catch { break }
    }

    $children = New-Object System.Collections.Generic.List[string]
    try {
        $childNodes = $Element.FindAll([System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.Condition]::TrueCondition)
        for ($index = 0; $index -lt [Math]::Min($childNodes.Count, 16); $index++) {
            $child = $childNodes.Item($index).Current
            $childClass = ConvertTo-LineUiaDiagnosticToken ([string]$child.ClassName)
            $childId = ConvertTo-LineUiaDiagnosticToken ([string]$child.AutomationId)
            $childType = [string]$child.ControlType.ProgrammaticName
            $children.Add(('{0}/{1}{2}' -f $childType, $childClass, $(if ($childId) { '[id=' + $childId + ']' } else { '' })))
        }
    } catch { }

    return [pscustomobject]@{ Path = ($path -join '<-'); Children = ($children -join ';') }
}

function Invoke-Element {
    param([System.Windows.Automation.AutomationElement]$Element)
    try {
        $pattern = $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $pattern.Invoke()
        return $true
    } catch { }
    try {
        $pattern = $Element.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern)
        $pattern.DoDefaultAction()
        return $true
    } catch { }
    try {
        $pattern = $Element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
        $pattern.Select()
        return $true
    } catch { }
    return $false
}

function Open-LineGroup {
    param([string]$DisplayName)
    if (-not $script:GroupElements.ContainsKey($DisplayName)) {
        $script:GroupElements = Get-GroupElements
    }
    if (-not $script:GroupElements.ContainsKey($DisplayName)) {
        throw '所選群組已不在目前畫面清單中。請重新掃描並選擇一次。'
    }
    $entry = $script:GroupElements[$DisplayName]
    if ($entry.CurrentConversation) {
        $line = $entry.Line
        if ($null -eq $line) { $line = Get-LineWindow }
        return [pscustomobject]@{ Name = $entry.Name; Line = $line }
    }
    $line = Get-LineWindow
    if (-not (Invoke-Element $entry.Element)) {
        throw 'LINE 輔助使用介面無法在背景選取所選聊天室；未移動滑鼠或切換視窗。可手動匯入 LINE 聊天記錄。'
    }
    Start-Sleep -Milliseconds 900
    $line = Get-LineWindow
    return [pscustomobject]@{ Name = $entry.Name; Line = $line }
}

function Test-LineSaveChatMenuBranch {
    param([System.Windows.Automation.AutomationElement]$Element)
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $ancestor = $Element
    $contextPattern = '(邀請|照片|影片|檔案|連結|投票|詳細設定|背景設定|退出聊天室|chat\s+list)'
    for ($depth = 0; $depth -lt 5; $depth++) {
        try { $ancestor = $walker.GetParent($ancestor) } catch { return $false }
        if ($null -eq $ancestor) { return $false }
        try {
            $branch = $ancestor.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.Condition]::TrueCondition)
            if ($branch.Count -gt 180) { continue }
            $contextLabels = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($node in $branch) {
                try {
                    $label = Get-ElementAccessibleLabel -Element $node
                    if ($label -match $contextPattern) { [void]$contextLabels.Add($label) }
                } catch { }
            }
            if ($contextLabels.Count -ge 3) { return $true }
        } catch { }
    }
    return $false
}

function Get-LineSaveChatControl {
    param([LineChatSummaryWindowInfo]$WindowInfo)
    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
    $elements = $desktop.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    $savePattern = '(?i)^\s*(儲存聊天|儲存聊天記錄|保存聊天|save\s+chat)\s*$'
    $matchItems = New-Object System.Collections.Generic.List[object]
    $menuTypeCounts = @{}
    $contextMatches = 0
    foreach ($element in $elements) {
        try {
            $typeName = [string]$element.Current.ControlType.ProgrammaticName
            if ($typeName -notin @('ControlType.MenuItem', 'ControlType.ListItem', 'ControlType.Button', 'ControlType.Text', 'ControlType.Custom')) { continue }
            $name = Get-ElementAccessibleLabel -Element $element
            if ($name -notmatch $savePattern) { continue }

            $elementPid = [int]$element.Current.ProcessId
            $isRelated = ($elementPid -eq $WindowInfo.ProcessId)
            $nativeHandle = [IntPtr]([int]$element.Current.NativeWindowHandle)
            if (-not $isRelated -and $nativeHandle -ne [IntPtr]::Zero) {
                $isRelated = [LineChatSummaryNative]::IsWindowRelatedToLine(
                    $nativeHandle, $WindowInfo.Handle, [int[]]@($WindowInfo.ProcessId))
            }
            if (-not $isRelated) {
                $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
                $ancestor = $element
                for ($depth = 0; $depth -lt 6 -and -not $isRelated; $depth++) {
                    try { $ancestor = $walker.GetParent($ancestor) } catch { break }
                    if ($null -eq $ancestor) { break }
                    try {
                        $ancestorHandle = [IntPtr]([int]$ancestor.Current.NativeWindowHandle)
                        if ($ancestorHandle -ne [IntPtr]::Zero) {
                            $isRelated = [LineChatSummaryNative]::IsWindowRelatedToLine(
                                $ancestorHandle, $WindowInfo.Handle, [int[]]@($WindowInfo.ProcessId))
                        }
                    } catch { }
                }
            }
            $contextConfirmed = Test-LineSaveChatMenuBranch -Element $element
            if (-not $isRelated -and -not $contextConfirmed) { continue }
            if ($contextConfirmed -and -not $isRelated) { $contextMatches++ }
            if (-not $menuTypeCounts.ContainsKey($typeName)) { $menuTypeCounts[$typeName] = 0 }
            $menuTypeCounts[$typeName]++
            $matchItems.Add([pscustomobject]@{ Element = $element; Type = $typeName; ProcessId = $elementPid; Related = $isRelated })
        } catch { }
    }
    $menuTypeSummary = @($menuTypeCounts.Keys | Sort-Object | ForEach-Object { '{0}:{1}' -f $_, $menuTypeCounts[$_] }) -join ','
    Write-AppLog ('SaveChatItemDiscovery scope=desktop-semantic-menu pid={0} matches={1} unownedMenuContextMatches={2} accessibleTypes={3}' -f $WindowInfo.ProcessId, $matchItems.Count, $contextMatches, $menuTypeSummary) 'DEBUG'
    if ($matchItems.Count -eq 1) { return $matchItems[0].Element }
    if ($matchItems.Count -gt 1) { Write-AppLog ('SaveChatItemAmbiguous matches={0}' -f $matchItems.Count) 'WARN' }
    return $null
}

function Get-LineOcrLinesFromBitmap {
    param([System.Drawing.Bitmap]$Bitmap)
    $engine = Initialize-LineGroupOcr
    $scale = 2
    $scaled = $null
    $graphics = $null
    $stream = $null
    $decoder = $null
    $softwareBitmap = $null
    $tempImage = Join-Path ([System.IO.Path]::GetTempPath()) ('LineChatSummary-MenuOCR-{0}.png' -f [guid]::NewGuid().ToString('N'))
    try {
        $scaled = New-Object System.Drawing.Bitmap(($Bitmap.Width * $scale), ($Bitmap.Height * $scale))
        $graphics = [System.Drawing.Graphics]::FromImage($scaled)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.DrawImage($Bitmap, (New-Object System.Drawing.Rectangle(0, 0, ($Bitmap.Width * $scale), ($Bitmap.Height * $scale))))
        $scaled.Save($tempImage, [System.Drawing.Imaging.ImageFormat]::Png)
        $file = Invoke-LineWinRtAsync ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tempImage)) ([Windows.Storage.StorageFile])
        $stream = Invoke-LineWinRtAsync ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        $decoder = Invoke-LineWinRtAsync ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $softwareBitmap = Invoke-LineWinRtAsync ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $ocrResult = Invoke-LineWinRtAsync ($engine.RecognizeAsync($softwareBitmap)) ([Windows.Media.Ocr.OcrResult])
        $result = New-Object System.Collections.Generic.List[object]
        foreach ($ocrLine in $ocrResult.Lines) {
            $bounds = $ocrLine.BoundingRect
            $result.Add([pscustomobject]@{
                Text = ([string]$ocrLine.Text).Trim()
                X = [int][Math]::Round(([double]$bounds.X + ([double]$bounds.Width / 2)) / $scale)
                Y = [int][Math]::Round(([double]$bounds.Y + ([double]$bounds.Height / 2)) / $scale)
            })
        }
        return ,$result.ToArray()
    } finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $scaled) { $scaled.Dispose() }
        try { if ($null -ne $softwareBitmap) { $softwareBitmap.Dispose() } } catch { }
        try { if ($null -ne $stream) { $stream.Close() } } catch { }
        try { if ($null -ne $stream) { $stream.Dispose() } } catch { }
        try { if ($null -ne $decoder) { $decoder.Dispose() } } catch { }
        if (Test-Path -LiteralPath $tempImage) { Remove-Item -LiteralPath $tempImage -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-LineSaveChatByPopupOcr {
    param([LineChatSummaryWindowInfo]$WindowInfo)
    $popupWindows = [LineChatSummaryNative]::GetPopupWindows(
        [int[]]@($WindowInfo.ProcessId), $WindowInfo.Handle)
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($popup in $popupWindows) {
        $candidates.Add($popup)
    }
    $foreignPids = @($candidates | Where-Object { $_.ProcessId -ne $WindowInfo.ProcessId } | Select-Object -ExpandProperty ProcessId -Unique)
    $foreignSummary = 'none'
    if ($foreignPids.Count -gt 0) { $foreignSummary = ($foreignPids -join ',') }
    $windowSummary = @($popupWindows | ForEach-Object {
        '{0}:pid={1}:related={2}:size={3}x{4}' -f $_.WindowClass, $_.ProcessId, $_.RelatedToLine, $_.Width, $_.Height
    }) -join ';'
    if ([string]::IsNullOrWhiteSpace($windowSummary)) { $windowSummary = 'none' }
    Write-AppLog ('SaveChatPopupDiscovery strategy=owner-process-active-popup-and-foreground-semantic-check windowHandles={0} candidates={1} foreignPids={2} windows={3}' -f $popupWindows.Count, $candidates.Count, $foreignSummary, $windowSummary) 'DEBUG'
    $targetMatches = New-Object System.Collections.Generic.List[object]
    foreach ($popup in $candidates) {
        $popupRoot = $null
        try {
            $popupRoot = [System.Windows.Automation.AutomationElement]::FromHandle($popup.Handle)
            if ($null -ne $popupRoot) {
                $popupElements = Get-DescendantsByProcess -Root $popupRoot -ProcessId $popup.ProcessId
                $popupSaveMatches = New-Object System.Collections.Generic.List[object]
                $popupContextLabels = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($element in $popupElements) {
                    try {
                        $typeName = [string]$element.Current.ControlType.ProgrammaticName
                        if ($typeName -notin @('ControlType.MenuItem', 'ControlType.ListItem', 'ControlType.Button', 'ControlType.Text', 'ControlType.Custom')) { continue }
                        if ($element.Current.IsOffscreen) { continue }
                        $label = Get-ElementAccessibleLabel -Element $element
                        if ($label -match '(邀請|照片|影片|檔案|連結|投票|詳細設定|背景設定|退出聊天室|chat\s+list)') { [void]$popupContextLabels.Add($label) }
                        if ($label -match '(?i)^\s*(儲存聊天|儲存聊天記錄|保存聊天|save\s+chat)\s*$') {
                            $popupSaveMatches.Add($element)
                        }
                    } catch { }
                }
                $popupSemanticallyConfirmed = ($popup.RelatedToLine -or $popupContextLabels.Count -ge 3)
                Write-AppLog ('SaveChatPopupUiaDiscovery pid={0} related={1} elements={2} targetMatches={3} contextLabels={4} semanticConfirmed={5}' -f $popup.ProcessId, $popup.RelatedToLine, $popupElements.Count, $popupSaveMatches.Count, $popupContextLabels.Count, $popupSemanticallyConfirmed) 'DEBUG'
                if ($popupSaveMatches.Count -eq 1 -and $popupSemanticallyConfirmed -and (Invoke-Element $popupSaveMatches[0])) {
                    Write-AppLog ('SaveChatItemSelected method=popup-window-uia pid={0}' -f $popup.ProcessId)
                    return $true
                }
            }
        } catch {
            Write-AppLog ('SaveChatPopupUiaFailed pid={0} category={1}' -f $popup.ProcessId, $_.Exception.GetType().Name) 'DEBUG'
        }
        $sources = New-Object System.Collections.Generic.List[object]
        $printCapture = $null
        try {
            $printCapture = Get-LineWindowCapture -WindowInfo $popup
            $sources.Add([pscustomobject]@{ Method = 'PrintWindow'; Bitmap = $printCapture })
            $printCapture = $null
        } catch { Write-AppLog ('SaveChatPopupCaptureFailed method=PrintWindow category={0}' -f $_.Exception.GetType().Name) 'DEBUG' }

        $popupMatched = $false
        foreach ($source in $sources) {
            try {
                $ocrLines = @(Get-LineOcrLinesFromBitmap -Bitmap $source.Bitmap)
                $contextCount = 0
                $menuMatches = New-Object System.Collections.Generic.List[object]
                foreach ($line in $ocrLines) {
                    if ($line.Text -match '(邀請|照片|影片|檔案|連結|投票|詳細設定|背景設定|退出聊天室|chat\s+list)') { $contextCount++ }
                    if ($line.Text -match '(?i)^\s*(儲存聊天|儲存聊天記錄|保存聊天|save\s+chat)\s*$') {
                        $menuMatches.Add([pscustomobject]@{ X = $line.X; Y = $line.Y })
                    }
                }
                $requiredContextLabels = 2
                if (-not $popup.RelatedToLine) { $requiredContextLabels = 3 }
                Write-AppLog ('SaveChatPopupOcrDiscovery method={0} related={1} zOrder={2} size={3}x{4} lines={5} targetMatches={6} menuContextLabels={7}' -f $source.Method, $popup.RelatedToLine, $popup.ZOrder, $popup.Width, $popup.Height, $ocrLines.Count, $menuMatches.Count, $contextCount) 'DEBUG'
                if ($menuMatches.Count -eq 1 -and $contextCount -ge $requiredContextLabels) {
                    $match = $menuMatches[0]
                    $targetMatches.Add([pscustomobject]@{ Window = $popup; X = $match.X; Y = $match.Y; Method = $source.Method })
                    $popupMatched = $true
                }
            } catch {
                Write-AppLog ('SaveChatPopupOcrFailed method={0} category={1}' -f $source.Method, $_.Exception.GetType().Name) 'WARN'
            } finally {
                $source.Bitmap.Dispose()
            }
        }
        if (-not $popupMatched) {
            $screenCapture = $null
            $screenGraphics = $null
            try {
                $screenCapture = New-Object System.Drawing.Bitmap([int]$popup.Width, [int]$popup.Height)
                $screenGraphics = [System.Drawing.Graphics]::FromImage($screenCapture)
                $screenGraphics.CopyFromScreen([int]$popup.Left, [int]$popup.Top, 0, 0, $screenCapture.Size)
                $ocrLines = @(Get-LineOcrLinesFromBitmap -Bitmap $screenCapture)
                $contextCount = 0
                $menuMatches = New-Object System.Collections.Generic.List[object]
                foreach ($line in $ocrLines) {
                    if ($line.Text -match '(邀請|照片|影片|檔案|連結|投票|詳細設定|背景設定|退出聊天室|chat\s+list)') { $contextCount++ }
                    if ($line.Text -match '(?i)(儲存聊天|保存聊天|save\s+chat)') {
                        $menuMatches.Add([pscustomobject]@{ X = $line.X; Y = $line.Y })
                    }
                }
                $requiredContextLabels = 2
                if (-not $popup.RelatedToLine) { $requiredContextLabels = 3 }
                Write-AppLog ('SaveChatPopupOcrDiscovery method=popup-region related={0} zOrder={1} size={2}x{3} lines={4} targetMatches={5} menuContextLabels={6}' -f $popup.RelatedToLine, $popup.ZOrder, $popup.Width, $popup.Height, $ocrLines.Count, $menuMatches.Count, $contextCount) 'DEBUG'
                if ($menuMatches.Count -eq 1 -and $contextCount -ge $requiredContextLabels) {
                    $match = $menuMatches[0]
                    $targetMatches.Add([pscustomobject]@{ Window = $popup; X = $match.X; Y = $match.Y; Method = 'popup-region' })
                    $popupMatched = $true
                }
            } catch {
                Write-AppLog ('SaveChatPopupCaptureFailed method=popup-region category={0}' -f $_.Exception.GetType().Name) 'DEBUG'
            } finally {
                if ($null -ne $screenGraphics) { $screenGraphics.Dispose() }
                if ($null -ne $screenCapture) { $screenCapture.Dispose() }
            }
        }
    }
    if ($targetMatches.Count -ne 1) { return $false }
    $target = $targetMatches[0]
    if (-not [LineChatSummaryNative]::ClickWindowClient($target.Window.Handle, $target.X, $target.Y)) {
        Write-AppLog ('SaveChatPopupMessageFailed method={0}' -f $target.Method) 'WARN'
        return $false
    }
    Write-AppLog ('SaveChatItemSelected method=popup-window-message capture={0} cursorMoved=false' -f $target.Method)
    Start-Sleep -Milliseconds 350
    return $true
}

function Invoke-LineSaveChatByBackgroundOcr {
    param([LineChatSummaryWindowInfo]$WindowInfo)
    if (-not $WindowInfo.IsVisible -or $WindowInfo.IsMinimized) {
        Write-AppLog ('SaveChatOcrSkipped visible={0} minimized={1}' -f $WindowInfo.IsVisible, $WindowInfo.IsMinimized) 'WARN'
        return $false
    }
    $capture = $null
    try {
        $capture = Get-LineWindowCapture -WindowInfo $WindowInfo
        $ocrLines = @(Get-LineOcrLinesFromBitmap -Bitmap $capture)
        $matches = New-Object System.Collections.Generic.List[object]
        $menuContextLabels = 0
        foreach ($line in $ocrLines) {
            if ($line.Text -match '(邀請|照片|影片|檔案|連結|投票|詳細設定|背景設定|退出聊天室|chat\s+list)') { $menuContextLabels++ }
            if ($line.Text -notmatch '(?i)(儲存聊天|保存聊天|save\s+chat)') { continue }
            $matches.Add([pscustomobject]@{ X = $line.X; Y = $line.Y })
        }
        Write-AppLog ('SaveChatOcrDiscovery strategy=whole-line-window lines={0} targetMatches={1} menuContextLabels={2}' -f $ocrLines.Count, $matches.Count, $menuContextLabels) 'DEBUG'
        if ($matches.Count -ne 1 -or $menuContextLabels -lt 2) { return $false }
        $target = $matches[0]
        if (-not [LineChatSummaryNative]::ClickWindowClient($WindowInfo.Handle, $target.X, $target.Y)) {
            Write-AppLog 'SaveChatBackgroundMessageFailed method=ocr-matched-text' 'WARN'
            return $false
        }
        Write-AppLog 'SaveChatItemSelected method=whole-window-ocr-message cursorMoved=false'
        Start-Sleep -Milliseconds 350
        return $true
    } catch {
        Write-AppLog ('SaveChatOcrFailed category={0}' -f $_.Exception.GetType().Name) 'WARN'
        return $false
    } finally {
        if ($null -ne $capture) { $capture.Dispose() }
    }
}

function Invoke-LineSaveChat {
    param([System.Windows.Automation.AutomationElement]$Root, [LineChatSummaryWindowInfo]$WindowInfo)
    $elements = Get-DescendantsByProcess -Root $Root -ProcessId $WindowInfo.ProcessId
    $saveItem = Get-LineSaveChatControl -WindowInfo $WindowInfo
    if ($null -ne $saveItem) {
        if (Invoke-Element $saveItem) {
            Write-AppLog 'SaveChatItemSelected method=UIA-existing-menu'
            return
        }
    }

    $menuPattern = '(?i)(更多|選單|功能表|more|menu|options|overflow|ellipsis|⋯|⋮|…)'
    $semanticCandidates = New-Object System.Collections.Generic.List[object]
    $anonymousCandidates = New-Object System.Collections.Generic.List[object]
    foreach ($element in $elements) {
        try {
            if ($element.Current.IsOffscreen -and $WindowInfo.IsVisible -and -not $WindowInfo.IsMinimized) { continue }
            $typeName = [string]$element.Current.ControlType.ProgrammaticName
            if ($typeName -notin @('ControlType.Button', 'ControlType.Group', 'ControlType.Custom')) { continue }
            $name = Get-ElementAccessibleLabel -Element $element
            $current = $element.Current
            $automationId = [string]$current.AutomationId
            $className = [string]$current.ClassName
            $localizedType = [string]$current.LocalizedControlType
            $helpText = [string]$current.HelpText
            $frameworkId = [string]$current.FrameworkId
            $nativeHandle = [int]$current.NativeWindowHandle
            $canInvoke = $false
            try { $null = $element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern); $canInvoke = $true } catch { }
            if (-not $canInvoke) {
                try { $null = $element.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern); $canInvoke = $true } catch { }
            }
            $legacyRole = ''
            $legacyAction = ''
            $legacyState = ''
            try {
                $legacyPattern = $element.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern)
                $legacyRole = [string]$legacyPattern.Current.Role
                $legacyAction = ConvertTo-LineUiaDiagnosticToken ([string]$legacyPattern.Current.DefaultAction)
                $legacyState = [string]$legacyPattern.Current.State
            } catch { }
            $control = [pscustomobject]@{
                Element = $element; Name = $name; AutomationId = $automationId; ClassName = $className
                LocalizedType = $localizedType; HelpText = $helpText; FrameworkId = $frameworkId
                NativeHandle = $nativeHandle; CanInvoke = $canInvoke; Type = $typeName
                IsEnabled = [bool]$current.IsEnabled; IsOffscreen = [bool]$current.IsOffscreen
                IsKeyboardFocusable = [bool]$current.IsKeyboardFocusable; HasKeyboardFocus = [bool]$current.HasKeyboardFocus
                IsControlElement = [bool]$current.IsControlElement; IsContentElement = [bool]$current.IsContentElement
                LegacyRole = $legacyRole; LegacyAction = $legacyAction; LegacyState = $legacyState
            }
            $identity = '{0} {1} {2} {3} {4}' -f $name, $automationId, $className, $localizedType, $helpText
            if ($canInvoke -and $identity -match $menuPattern) { $semanticCandidates.Add($control) }
            elseif ($canInvoke -and [string]::IsNullOrWhiteSpace($name)) { $anonymousCandidates.Add($control) }
        } catch { }
    }
    Write-AppLog ('SaveChatMenuTriggerDiscovery strategy=UIA-semantics pid={0} elements={1} semanticCandidates={2} anonymousInvokable={3}' -f $WindowInfo.ProcessId, $elements.Count, $semanticCandidates.Count, $anonymousCandidates.Count)
    foreach ($control in $anonymousCandidates) {
        Write-AppLog ('SaveChatMenuAnonymousControl type={0} automationId={1} className={2} localizedType={3} framework={4} nativeHwnd={5}' -f $control.Type, $control.AutomationId, $control.ClassName, $control.LocalizedType, $control.FrameworkId, $control.NativeHandle) 'DEBUG'
    }
    $diagnosticButtons = @($anonymousCandidates | Where-Object { $_.ClassName -eq 'LcButton' })
    Write-AppLog ('SaveChatMenuStructureDiagnostics controls={0} className=LcButton' -f $diagnosticButtons.Count) 'DEBUG'
    for ($buttonIndex = 0; $buttonIndex -lt $diagnosticButtons.Count; $buttonIndex++) {
        $control = $diagnosticButtons[$buttonIndex]
        try {
            $structure = Get-LineUiaStructureSignature -Element $control.Element
            Write-AppLog ('SaveChatMenuControlStructure index={0} type={1} enabled={2} offscreen={3} focusable={4} focused={5} control={6} content={7} invoke={8} legacyRole={9} legacyAction={10} legacyState={11} path={12} children={13}' -f $buttonIndex, $control.Type, $control.IsEnabled, $control.IsOffscreen, $control.IsKeyboardFocusable, $control.HasKeyboardFocus, $control.IsControlElement, $control.IsContentElement, $control.CanInvoke, $control.LegacyRole, $control.LegacyAction, $control.LegacyState, $structure.Path, $structure.Children) 'DEBUG'
        } catch {
            Write-AppLog ('SaveChatMenuControlStructure index={0} metadataReadFailed={1}' -f $buttonIndex, $_.Exception.GetType().Name) 'DEBUG'
        }
    }

    $menuButton = $null
    if ($semanticCandidates.Count -eq 1) { $menuButton = $semanticCandidates[0] }
    elseif ($semanticCandidates.Count -gt 1) {
        $buttonMatches = @($semanticCandidates | Where-Object { $_.Type -eq 'ControlType.Button' })
        if ($buttonMatches.Count -eq 1) { $menuButton = $buttonMatches[0] }
        else { Write-AppLog ('SaveChatMenuTriggerAmbiguous semanticCandidates={0} buttons={1}' -f $semanticCandidates.Count, $buttonMatches.Count) 'WARN' }
    }
    elseif ($anonymousCandidates.Count -eq 1) { $menuButton = $anonymousCandidates[0] }
    if ($null -eq $menuButton) {
        Write-AppLog ('SaveChatMenuTriggerUnavailable semanticCandidates={0} anonymousInvokable={1}; no coordinate fallback used' -f $semanticCandidates.Count, $anonymousCandidates.Count) 'WARN'
        throw 'LINE 的 UI Automation 控制項沒有提供唯一可辨識名稱；父子階層診斷已寫入本機日誌（SaveChatMenuControlStructure）。工具沒有猜測按鈕或移動滑鼠。'
    }
    if (-not (Invoke-Element $menuButton.Element)) {
        throw 'LINE 輔助使用介面無法呼叫已辨識的聊天室選單控制項；工具未移動滑鼠。可匯入 LINE 手動儲存的聊天記錄。'
    }
    Write-AppLog ('SaveChatMenuInvokeReturned method=UIA-semantic type={0} automationId={1} className={2}; popup state is not yet confirmed' -f $menuButton.Type, $menuButton.AutomationId, $menuButton.ClassName)
    Start-Sleep -Milliseconds 350

    $saveItem = Get-LineSaveChatControl -WindowInfo $WindowInfo
    if ($null -ne $saveItem -and (Invoke-Element $saveItem)) {
        Write-AppLog 'SaveChatItemSelected method=UIA-desktop-tree'
        return
    }
    if (Invoke-LineSaveChatByPopupOcr -WindowInfo $WindowInfo) { return }
    if (Invoke-LineSaveChatByBackgroundOcr -WindowInfo $WindowInfo) { return }
    Write-AppLog 'SaveChatMenuStateUnconfirmed uiaInvocationReturned=true saveItemFound=false popupOcrMatch=false' 'WARN'
    throw 'LINE 輔助使用介面與彈出視窗辨識都未找到「儲存聊天」項目；工具沒有切換前景或移動滑鼠。可查看本機日誌，或匯入 LINE 儲存的聊天記錄。'
}
function Get-DownloadsFolder {
    $path = Join-Path $env:USERPROFILE 'Downloads'
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
    return $path
}

function Get-TxtSnapshot {
    param([string]$Folder)
    $snapshot = @{}
    if (Test-Path -LiteralPath $Folder) {
        foreach ($file in (Get-ChildItem -LiteralPath $Folder -Filter '*.txt' -File -ErrorAction SilentlyContinue)) {
            $snapshot[$file.FullName] = '{0}:{1}' -f $file.Length, $file.LastWriteTimeUtc.Ticks
        }
    }
    return $snapshot
}

function Wait-NewTranscript {
    param([string]$Folder, [hashtable]$Before, [datetime]$StartedAt)
    $deadline = (Get-Date).AddSeconds(35)
    while ((Get-Date) -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        $matches = @()
        foreach ($file in (Get-ChildItem -LiteralPath $Folder -Filter '*.txt' -File -ErrorAction SilentlyContinue)) {
            $signature = '{0}:{1}' -f $file.Length, $file.LastWriteTimeUtc.Ticks
            $wasSame = $Before.ContainsKey($file.FullName) -and $Before[$file.FullName] -eq $signature
            if (-not $wasSame -and $file.LastWriteTime -ge $StartedAt.AddSeconds(-2) -and $file.Length -gt 0) { $matches += $file }
        }
        if ($matches.Count -gt 0) {
            return ($matches | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
        }
        Start-Sleep -Milliseconds 650
    }
    return $null
}

function Select-TranscriptFile {
    param([string]$InitialDirectory)
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = '選擇 LINE 匯出的聊天文字檔'
    $dialog.Filter = 'LINE 聊天文字檔 (*.txt)|*.txt|所有檔案 (*.*)|*.*'
    $dialog.Multiselect = $false
    if (Test-Path -LiteralPath $InitialDirectory) { $dialog.InitialDirectory = $InitialDirectory }
    if ($dialog.ShowDialog($script:form) -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.FileName }
    return $null
}

function Get-TranscriptText {
    param([string]$Path)
    $reader = New-Object System.IO.StreamReader($Path, $true)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Convert-TranscriptDate {
    param([string]$Text)
    $clean = [regex]::Replace($Text, '\s*(?:\([^)]*\)|（[^）]*）)\s*$', '')
    $clean = [regex]::Replace($clean, '(?i)(?:星期|週|周)\s*[一二三四五六日天0-6A-Za-z]+', '')
    $clean = [regex]::Replace($clean, '(?i)\b(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|Mon|Tue|Wed|Thu|Fri|Sat|Sun)\b', '')
    $clean = $clean -replace '[\[\]\(\)（）\s]', ''
    $clean = $clean -replace '年', '/'
    $clean = $clean -replace '月', '/'
    $clean = $clean -replace '日', ''
    $clean = $clean -replace '\.', '/'
    $clean = $clean.TrimEnd('/')
    # The .NET overload that accepts multiple date formats requires string[].
    # A PowerShell object[] silently failed to match LINE's exported date headers.
    $formats = [string[]]@('yyyy/M/d', 'yyyy/MM/dd', 'yyyy/M/dd', 'yyyy/MM/d', 'yyyy-M-d', 'yyyy-MM-dd', 'yyyy-M-dd', 'yyyy-MM-d', 'M/d/yyyy', 'MM/dd/yyyy', 'M/dd/yyyy', 'MM/d/yyyy')
    $cultures = @([Globalization.CultureInfo]::GetCultureInfo('zh-TW'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.CultureInfo]::GetCultureInfo('en-US'))
    $parsed = [datetime]::MinValue
    foreach ($culture in $cultures) {
        if ([datetime]::TryParseExact($clean, $formats, $culture, [Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$parsed)) {
            return $parsed.Date
        }
    }
    return $null
}

function Convert-TranscriptTime {
    param([string]$Text)
    $clean = $Text.Trim().Replace('上午', 'AM').Replace('下午', 'PM')
    if ($clean -match '^(?<ampm>AM|PM)\s*(?<clock>\d{1,2}:\d{2}(?::\d{2})?)$') { $clean = $Matches.clock + ' ' + $Matches.ampm }
    $parsed = [datetime]::MinValue
    foreach ($culture in @([Globalization.CultureInfo]::GetCultureInfo('zh-TW'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.CultureInfo]::GetCultureInfo('en-US'))) {
        if ([datetime]::TryParse($clean, $culture, [Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$parsed)) { return $parsed.TimeOfDay }
    }
    return $null
}

function Split-TranscriptSenderBody {
    param([string]$Rest)
    $sender = ''
    $body = $Rest
    if ($Rest.Contains("`t")) {
        $parts = $Rest.Split(@("`t"), 2, [StringSplitOptions]::None)
        if ($parts.Count -eq 2) { $sender = $parts[0].Trim(); $body = $parts[1] }
    } elseif ($Rest -match '^\s*(?<sender>[^:：]{1,40})[:：]\s+(?<body>.*)$') {
        $sender = $Matches.sender.Trim()
        $body = $Matches.body
    } elseif ($Rest -match '^\s*(?<sender>\S.{0,38}?)\s{2,}(?<body>.*)$') {
        $sender = $Matches.sender.Trim()
        $body = $Matches.body
    }
    return [pscustomobject]@{ Sender = $sender; Body = $body }
}

function Parse-Transcript {
    param(
        [string]$Text,
        [datetime]$Start = [datetime]::MinValue,
        [datetime]$End = [datetime]::MaxValue
    )
    $messages = New-Object System.Collections.Generic.List[object]
    $current = $null
    $currentDate = $null
    $dateToken = '(?<date>\d{1,4}\s*(?:[-/.]|年)\s*\d{1,2}\s*(?:[-/.]|月)\s*\d{1,4}\s*(?:日|\.)?)'
    $weekday = '(?:\s*(?:\([^)]{1,16}\)|（[^）]{1,16}）|星期[一二三四五六日天]|週[一二三四五六日天]))?'
    $timeToken = '(?<time>(?:(?:上午|下午|AM|PM)\s*)?\d{1,2}:\d{2}(?::\d{2})?(?:\s*(?:AM|PM|上午|下午))?)'
    $dateTimePattern = '^\s*\[?' + $dateToken + $weekday + '[ T\t]+' + $timeToken + '\]?[\t ]+(?<rest>.*)$'
    $dateHeaderPattern = '^\s*\[?' + $dateToken + $weekday + '\]?\s*$'
    $timeOnlyPattern = '^\s*\[?' + $timeToken + '\]?[\t ]+(?<rest>.*)$'
    foreach ($line in ($Text -split "\r?\n")) {
        $match = [regex]::Match($line, $dateTimePattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            $dateValue = Convert-TranscriptDate $match.Groups['date'].Value
            $timeValue = Convert-TranscriptTime $match.Groups['time'].Value
            if ($null -eq $dateValue -or $null -eq $timeValue) { continue }
            if ($null -ne $current) { $messages.Add($current) }
            $stamp = $dateValue.Date.Add($timeValue)
            $currentDate = $dateValue.Date
            if ($stamp -ge $Start -and $stamp -le $End) {
                $parts = Split-TranscriptSenderBody $match.Groups['rest'].Value
                $current = [pscustomobject]@{ Timestamp = $stamp; Sender = $parts.Sender; Body = $parts.Body }
            } else { $current = $null }
            continue
        }
        $match = [regex]::Match($line, $dateHeaderPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            if ($null -ne $current) { $messages.Add($current); $current = $null }
            $currentDate = Convert-TranscriptDate $match.Groups['date'].Value
            continue
        }
        $match = [regex]::Match($line, $timeOnlyPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success -and $null -ne $currentDate) {
            $timeValue = Convert-TranscriptTime $match.Groups['time'].Value
            if ($null -ne $timeValue) {
                if ($null -ne $current) { $messages.Add($current) }
                $stamp = $currentDate.Date.Add($timeValue)
                if ($stamp -ge $Start -and $stamp -le $End) {
                    $parts = Split-TranscriptSenderBody $match.Groups['rest'].Value
                    $current = [pscustomobject]@{ Timestamp = $stamp; Sender = $parts.Sender; Body = $parts.Body }
                } else { $current = $null }
                continue
            }
        }
        if ($null -ne $current) {
            $current.Body += [Environment]::NewLine + $line
        }
    }
    if ($null -ne $current) { $messages.Add($current) }
    return ,$messages.ToArray()
}

function Write-TranscriptParseDiagnostics {
    param([string]$Text)
    $lines = @($Text -split "\r?\n")
    $dateToken = '(?<date>\d{1,4}\s*(?:[-/.]|年)\s*\d{1,2}\s*(?:[-/.]|月)\s*\d{1,4}\s*(?:日|\.)?)'
    $weekday = '(?:\s*(?:\([^)]{1,16}\)|（[^）]{1,16}）|星期[一二三四五六日天]|週[一二三四五六日天]))?'
    $timeToken = '(?<time>(?:(?:上午|下午|AM|PM)\s*)?\d{1,2}:\d{2}(?::\d{2})?(?:\s*(?:AM|PM|上午|下午))?)'
    $dateTimePattern = '^\s*\[?' + $dateToken + $weekday + '[ T\t]+' + $timeToken + '\]?[\t ]+'
    $dateHeaderPattern = '^\s*\[?' + $dateToken + $weekday + '\]?\s*$'
    $timeOnlyPattern = '^\s*\[?' + $timeToken + '\]?[\t ]+'
    $nonEmptyCount = 0
    $dateTimeCount = 0
    $dateHeaderCount = 0
    $timeOnlyCount = 0
    $sampleCount = 0
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $nonEmptyCount++
        $kind = 'other'
        if ($line -match $dateTimePattern) { $dateTimeCount++; $kind = 'date-time' }
        elseif ($line -match $dateHeaderPattern) { $dateHeaderCount++; $kind = 'date-header' }
        elseif ($line -match $timeOnlyPattern) { $timeOnlyCount++; $kind = 'time-only' }
        if ($sampleCount -lt 8) {
            $sampleCount++
            $shape = [regex]::Replace($line, '\d+', '{N}')
            $shape = [regex]::Replace($shape, '[\p{L}\p{M}]+', '{T}')
            $shape = [regex]::Replace($shape, '\s+', '{WS}')
            if ($shape.Length -gt 140) { $shape = $shape.Substring(0, 140) }
            Write-AppLog ('TranscriptLineShape sample={0} kind={1} chars={2} tabs={3} shape={4}' -f $sampleCount, $kind, $line.Length, ([regex]::Matches($line, "`t")).Count, $shape) 'WARN'
        }
    }
    Write-AppLog ('TranscriptParseNoMatches chars={0} lines={1} nonEmpty={2} dateTimeLines={3} dateHeaders={4} timeOnlyLines={5}' -f $Text.Length, $lines.Count, $nonEmptyCount, $dateTimeCount, $dateHeaderCount, $timeOnlyCount) 'ERROR'
}

function Select-RangeMessages {
    param([object[]]$Messages, [datetime]$Start, [datetime]$End)
    return ,@($Messages | Where-Object { $_.Timestamp -ge $Start -and $_.Timestamp -le $End } | Sort-Object Timestamp)
}

function Remove-CommonPII {
    param([string]$Text)
    $masked = [regex]::Replace($Text, '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', '[EMAIL]')
    $masked = [regex]::Replace($masked, '(?<!\d)(?:\+?886[- ]?)?09\d{2}[- ]?\d{3}[- ]?\d{3}(?!\d)', '[PHONE]')
    return $masked
}

function Format-MessagesForAI {
    param([object[]]$Messages, [bool]$Redact)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($message in $Messages) {
        $body = [string]$message.Body
        if ($Redact) { $body = Remove-CommonPII $body }
        $sender = [string]$message.Sender
        if ($Redact) { $sender = Remove-CommonPII $sender }
        $prefix = '[{0}]' -f $message.Timestamp.ToString('yyyy-MM-dd HH:mm:ss')
        if (-not [string]::IsNullOrWhiteSpace($sender)) { $prefix += ' ' + $sender + ':' }
        $lines.Add($prefix + ' ' + $body)
    }
    return ($lines -join [Environment]::NewLine)
}

function Split-TranscriptChunks {
    param([string]$Text, [int]$Limit = 14000)
    $chunks = New-Object System.Collections.Generic.List[string]
    $builder = New-Object System.Text.StringBuilder
    foreach ($line in ($Text -split "\r?\n")) {
        $pending = $line
        while ($pending.Length -gt $Limit) {
            if ($builder.Length -gt 0) { $chunks.Add($builder.ToString()); $null = $builder.Clear() }
            $chunks.Add($pending.Substring(0, $Limit))
            $pending = $pending.Substring($Limit)
        }
        if (($builder.Length + $pending.Length + 1) -gt $Limit -and $builder.Length -gt 0) {
            $chunks.Add($builder.ToString())
            $null = $builder.Clear()
        }
        if ($builder.Length -gt 0) { $null = $builder.Append([Environment]::NewLine) }
        $null = $builder.Append($pending)
    }
    if ($builder.Length -gt 0) { $chunks.Add($builder.ToString()) }
    return ,$chunks.ToArray()
}

function Get-SafeFilePart {
    param([string]$Text)
    $safe = [regex]::Replace($Text, '[\\/:*?"<>|]', '_').Trim()
    $safe = [regex]::Replace($safe, '\s+', '_')
    if ($safe.Length -gt 55) { $safe = $safe.Substring(0, 55) }
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'LINE群組' }
    return $safe
}

function Read-ModeRequest {
    if ([string]::IsNullOrWhiteSpace($RequestPath) -or -not (Test-Path -LiteralPath $RequestPath -PathType Leaf)) {
        return [pscustomobject]@{}
    }
    return (Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Write-ModeResult {
    param([object]$Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 12 -Compress
    [Console]::WriteLine($json)
}

function Invoke-ModeScan {
    $script:GroupElements = Get-GroupElements
    $groups = @($script:GroupElements.Keys | Sort-Object | ForEach-Object { [string]$_ })
    $scope = 'unknown'
    $scopeHint = '只會列出 LINE 目前畫面可辨識的聊天室。'
    if ($script:LastGroupScanSidebarFound) {
        $scope = 'visible-list'
        $scopeHint = ('目前 LINE 畫面中有 {0} 個可辨識聊天室；未顯示或未載入的項目不會列出。' -f $groups.Count)
    } elseif ($script:LastGroupScanIndividualWindowAttempted -and $groups.Count -gt 0) {
        $scope = 'active-chat'
        $scopeHint = '這個 LINE 視窗沒有可讀取的聊天室清單，目前只辨識到已開啟的聊天室。要選其他群組，請切回 LINE 聊天清單再掃描。'
    }
    Write-AppLog ('WebGroupScanCompleted count={0} scope={1} sidebar={2}' -f $groups.Count, $scope, $script:LastGroupScanSidebarFound)
    return [pscustomobject]@{ ok = $true; groups = $groups; scope = $scope; scopeHint = $scopeHint }
}

function Invoke-ModeDetectChat {
    $script:LastCurrentChatName = ''
    $line = Get-LineWindow -CurrentChat
    $chatName = [string]$script:LastCurrentChatName
    if ([string]::IsNullOrWhiteSpace($chatName)) {
        try { $chatName = Get-LineActiveConversationName -WindowInfo $line.Info } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($chatName)) { $chatName = '目前開啟的聊天室' }
    Write-AppLog ('CurrentChatDetectionCompleted titleRead={0} visible={1} minimized={2}' -f ($chatName -ne '目前開啟的聊天室'), $line.Info.IsVisible, $line.Info.IsMinimized)
    return [pscustomobject]@{ ok = $true; groupName = $chatName }
}

function Invoke-ModeExportChat {
    param([object]$Request)
    $exportStarted = Get-Date
    Write-AppLog 'ChatExportStarted'
    $script:LastCurrentChatName = ''
    $line = Get-LineWindow -CurrentChat
    $groupName = [string]$script:LastCurrentChatName
    if ([string]::IsNullOrWhiteSpace($groupName)) {
        try { $groupName = Get-LineActiveConversationName -WindowInfo $line.Info } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($groupName)) { $groupName = '目前開啟的聊天室' }
    Write-AppLog ('ChatExportTargetSelected titleRead={0} zOrder={1} size={2}x{3}' -f ($groupName -ne '目前開啟的聊天室'), $line.Info.ZOrder, $line.Info.Width, $line.Info.Height)
    $downloadFolder = Get-DownloadsFolder
    $before = Get-TxtSnapshot $downloadFolder
    $saveStarted = Get-Date
    Invoke-LineSaveChat -Root $line.Element -WindowInfo $line.Info
    $sourcePath = Wait-NewTranscript -Folder $downloadFolder -Before $before -StartedAt $saveStarted
    if ([string]::IsNullOrWhiteSpace($sourcePath)) {
        Write-AppLog 'WebChatExportNeedsManualImport' 'WARN'
        return [pscustomobject]@{
            ok = $false
            requiresImport = $true
            error = 'LINE 沒有在下載資料夾產生新 TXT。請在 LINE 完成「儲存聊天」，再按「匯入 TXT」。'
        }
    }
    Write-AppLog ('WebChatExportCompleted durationMs={0}' -f [int](((Get-Date) - $exportStarted).TotalMilliseconds))
    return [pscustomobject]@{ ok = $true; sourcePath = $sourcePath; groupName = $groupName }
}

function Invoke-ModePrepareSummary {
    param([object]$Request)
    $prepareStarted = Get-Date
    $sourcePath = [string]$Request.sourcePath
    $groupName = [string]$Request.groupName
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw '找不到聊天 TXT，請重新匯入。' }
    if ([string]::IsNullOrWhiteSpace($groupName)) { $groupName = [System.IO.Path]::GetFileNameWithoutExtension($sourcePath) }
    $start = [datetime]::Parse([string]$Request.start, [Globalization.CultureInfo]::InvariantCulture)
    $end = [datetime]::Parse([string]$Request.end, [Globalization.CultureInfo]::InvariantCulture)
    $end = $end.AddMinutes(1).AddTicks(-1)
    if ($end -lt $start) { throw '結束時間必須晚於開始時間。' }
    $loadStarted = Get-Date
    $text = Get-TranscriptText -Path $sourcePath
    $sourceLength = (Get-Item -LiteralPath $sourcePath).Length
    $lineCount = @($text -split '\r?\n').Count
    Write-AppLog ('TranscriptLoaded bytes={0} chars={1} lines={2} durationMs={3}' -f $sourceLength, $text.Length, $lineCount, [int](((Get-Date) - $loadStarted).TotalMilliseconds))
    $parseStarted = Get-Date
    $allMessages = Parse-Transcript -Text $text -Start $start -End $end
    Write-AppLog ('TranscriptParsed rangeMessages={0} rangeFiltered=True durationMs={1}' -f $allMessages.Count, [int](((Get-Date) - $parseStarted).TotalMilliseconds))
    $selected = Select-RangeMessages -Messages $allMessages -Start $start -End $end
    if ($selected.Count -eq 0) {
        $allParsedMessages = Parse-Transcript -Text $text
        if ($allParsedMessages.Count -eq 0) {
            Write-TranscriptParseDiagnostics -Text $text
            throw '無法辨識這份 TXT 的日期時間格式；請確認檔案是 LINE 儲存的純文字聊天記錄。'
        }
        $first = ($allParsedMessages | Measure-Object -Property Timestamp -Minimum).Minimum
        $last = ($allParsedMessages | Measure-Object -Property Timestamp -Maximum).Maximum
        throw ('指定範圍沒有訊息。檔案可解析的日期範圍為 {0} 至 {1}。' -f $first.ToString('yyyy-MM-dd HH:mm'), $last.ToString('yyyy-MM-dd HH:mm'))
    }
    $formatStarted = Get-Date
    $formatted = Format-MessagesForAI -Messages $selected -Redact $true
    $firstSelected = ($selected | Measure-Object -Property Timestamp -Minimum).Minimum
    $lastSelected = ($selected | Measure-Object -Property Timestamp -Maximum).Maximum
    Write-AppLog ('SummaryInputPrepared messages={0} transcriptBytes={1} chars={2} formatMs={3} totalMs={4}' -f $selected.Count, $sourceLength, $formatted.Length, [int](((Get-Date) - $formatStarted).TotalMilliseconds), [int](((Get-Date) - $prepareStarted).TotalMilliseconds))
    return [pscustomobject]@{
        ok = $true
        text = $formatted
        count = $selected.Count
        groupName = $groupName
        start = $firstSelected.ToString('yyyy-MM-dd HH:mm')
        end = $lastSelected.ToString('yyyy-MM-dd HH:mm')
    }
}

function Invoke-ModeCleanupTranscript {
    param([object]$Request)
    $sourcePath = [string]$Request.sourcePath
    if ([string]::IsNullOrWhiteSpace($sourcePath)) { return [pscustomobject]@{ ok = $true; deleted = $false } }
    $downloadFolder = [System.IO.Path]::GetFullPath((Get-DownloadsFolder)).TrimEnd('\') + '\'
    $fullPath = [System.IO.Path]::GetFullPath($sourcePath)
    if (-not $fullPath.StartsWith($downloadFolder, [StringComparison]::OrdinalIgnoreCase) -or
        [System.IO.Path]::GetExtension($fullPath) -ne '.txt') {
        throw '暫存聊天檔不在 LINE 下載資料夾，未予刪除。'
    }
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        Remove-Item -LiteralPath $fullPath -Force
        Write-AppLog 'TemporaryLineTranscriptDeleted'
        return [pscustomobject]@{ ok = $true; deleted = $true }
    }
    return [pscustomobject]@{ ok = $true; deleted = $false }
}

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $request = Read-ModeRequest
    switch ($Mode) {
        'Scan' { $result = Invoke-ModeScan }
        'DetectChat' { $result = Invoke-ModeDetectChat }
        'ExportChat' { $result = Invoke-ModeExportChat -Request $request }
        'PrepareSummary' { $result = Invoke-ModePrepareSummary -Request $request }
        'CleanupTranscript' { $result = Invoke-ModeCleanupTranscript -Request $request }
        default { throw '不支援的操作模式。' }
    }
    Write-ModeResult -Value $result
    exit 0
} catch {
    Write-AppLog ('WebRequestFailed mode={0} category={1} line={2}' -f $Mode, $_.Exception.GetType().Name, $_.InvocationInfo.ScriptLineNumber) 'ERROR'
    Write-ModeResult -Value ([pscustomobject]@{ ok = $false; error = $_.Exception.Message })
    exit 1
}
