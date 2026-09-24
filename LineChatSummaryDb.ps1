param(
    [ValidateSet('ScanDbKeys')]
    [string]$Mode = 'ScanDbKeys'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

try {
    if (-not ('LineChatSummaryKeyScanner' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public sealed class LineChatSummaryKeyCandidate {
    public string Value { get; set; }
    public int Frequency { get; set; }
}

public static class LineChatSummaryKeyScanner {
    private const uint PROCESS_VM_READ = 0x0010;
    private const uint PROCESS_QUERY_INFORMATION = 0x0400;
    private const uint MEM_COMMIT = 0x1000;
    private const uint MEM_PRIVATE = 0x20000;
    private const uint PAGE_GUARD = 0x100;
    private const uint PAGE_NOACCESS = 0x01;
    private const int ChunkBytes = 8 * 1024 * 1024;
    private const int OverlapBytes = 64;
    private const ulong MaxUserAddress = 0x00007FFFFFFEFFFFUL;

    [StructLayout(LayoutKind.Sequential)]
    private struct MEMORY_BASIC_INFORMATION {
        public IntPtr BaseAddress;
        public IntPtr AllocationBase;
        public uint AllocationProtect;
        public ushort PartitionId;
        public IntPtr RegionSize;
        public uint State;
        public uint Protect;
        public uint Type;
    }

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern UIntPtr VirtualQueryEx(IntPtr process, IntPtr address,
        out MEMORY_BASIC_INFORMATION info, UIntPtr length);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool ReadProcessMemory(IntPtr process, IntPtr address,
        [Out] byte[] buffer, UIntPtr length, out UIntPtr read);

    private static bool IsHex(byte value) {
        return (value >= (byte)'0' && value <= (byte)'9') ||
               (value >= (byte)'a' && value <= (byte)'f') ||
               (value >= (byte)'A' && value <= (byte)'F');
    }
    private static bool IsWord(byte value) {
        return (value >= (byte)'0' && value <= (byte)'9') ||
               (value >= (byte)'a' && value <= (byte)'z') ||
               (value >= (byte)'A' && value <= (byte)'Z');
    }
    private static string HexString(byte[] data, int start, int stride) {
        char[] chars = new char[32];
        for (int i = 0; i < 32; i++) chars[i] = Char.ToLowerInvariant((char)data[start + i * stride]);
        return new string(chars);
    }
    private static void CountAscii(byte[] data, int length, int minStart, Dictionary<string, int> counts) {
        for (int i = minStart; i + 32 <= length; i++) {
            if (!IsHex(data[i])) continue;
            if (i > 0 && IsWord(data[i - 1])) continue;
            int j = i;
            while (j < length && IsHex(data[j])) j++;
            if (j - i == 32 && (j == length || !IsWord(data[j]))) {
                string key = HexString(data, i, 1);
                int frequency;
                counts.TryGetValue(key, out frequency);
                counts[key] = frequency + 1;
            }
            i = Math.Max(i, j - 1);
        }
    }
    private static void CountUtf16(byte[] data, int length, int minStart, Dictionary<string, int> counts) {
        for (int parity = 0; parity < 2; parity++) {
            for (int i = parity; i + 64 <= length; i += 2) {
                if (i < minStart) continue;
                bool matches = true;
                for (int n = 0; n < 32; n++) {
                    if (!IsHex(data[i + n * 2]) || data[i + n * 2 + 1] != 0) { matches = false; break; }
                }
                if (!matches) continue;
                if (i >= 2 && data[i - 1] == 0 && IsWord(data[i - 2])) continue;
                int end = i + 64;
                if (end + 1 < length && data[end + 1] == 0 && IsWord(data[end])) continue;
                string key = HexString(data, i, 2);
                int frequency;
                counts.TryGetValue(key, out frequency);
                counts[key] = frequency + 1;
                i += 62;
            }
        }
    }
    private static bool IsReadable(uint protect) {
        if ((protect & PAGE_GUARD) != 0 || (protect & 0xFF) == PAGE_NOACCESS) return false;
        uint basic = protect & 0xFF;
        return basic == 0x02 || basic == 0x04 || basic == 0x08 ||
               basic == 0x20 || basic == 0x40 || basic == 0x80;
    }

    public static List<LineChatSummaryKeyCandidate> Scan(int pid, int maxCandidates) {
        if (IntPtr.Size != 8) throw new InvalidOperationException("LINE 資料庫掃描需要 64 位元 PowerShell。");
        IntPtr process = OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, false, pid);
        if (process == IntPtr.Zero) throw new InvalidOperationException("無法唯讀存取 LINE 程序記憶體；請確認 LINE 已登入並以相同 Windows 使用者執行工具。");

        Dictionary<string, int> counts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        try {
            ulong address = 0;
            UIntPtr structureSize = new UIntPtr((uint)Marshal.SizeOf(typeof(MEMORY_BASIC_INFORMATION)));
            while (address < MaxUserAddress) {
                MEMORY_BASIC_INFORMATION info;
                UIntPtr queried = VirtualQueryEx(process, new IntPtr(unchecked((long)address)), out info, structureSize);
                if (queried == UIntPtr.Zero) break;
                ulong regionSize = unchecked((ulong)info.RegionSize.ToInt64());
                ulong baseAddress = unchecked((ulong)info.BaseAddress.ToInt64());
                if (regionSize == 0) break;

                if (info.State == MEM_COMMIT && info.Type == MEM_PRIVATE && IsReadable(info.Protect)) {
                    byte[] carry = new byte[OverlapBytes];
                    int carryLength = 0;
                    ulong offset = 0;
                    while (offset < regionSize) {
                        int requested = (int)Math.Min((ulong)ChunkBytes, regionSize - offset);
                        byte[] buffer = new byte[requested];
                        byte[] combined = null;
                        try {
                            UIntPtr bytesRead;
                            bool completeRead = ReadProcessMemory(process,
                                new IntPtr(unchecked((long)(baseAddress + offset))), buffer,
                                new UIntPtr((ulong)requested), out bytesRead);
                            int length = (int)Math.Min((ulong)buffer.Length, bytesRead.ToUInt64());
                            if (length == 0) break;
                            combined = new byte[carryLength + length];
                            if (carryLength > 0) Buffer.BlockCopy(carry, 0, combined, 0, carryLength);
                            Buffer.BlockCopy(buffer, 0, combined, carryLength, length);
                            CountAscii(combined, combined.Length, Math.Max(0, carryLength - 31), counts);
                            CountUtf16(combined, combined.Length, Math.Max(0, carryLength - 63), counts);

                            int nextCarryLength = Math.Min(OverlapBytes, combined.Length);
                            Array.Clear(carry, 0, carry.Length);
                            Buffer.BlockCopy(combined, combined.Length - nextCarryLength, carry, 0, nextCarryLength);
                            carryLength = nextCarryLength;
                            offset += (ulong)length;
                            if (!completeRead || length < requested) break;
                        } finally {
                            Array.Clear(buffer, 0, buffer.Length);
                            if (combined != null) Array.Clear(combined, 0, combined.Length);
                        }
                    }
                    Array.Clear(carry, 0, carry.Length);
                }

                ulong next = baseAddress + regionSize;
                if (next <= address || next > MaxUserAddress) break;
                address = next;
            }
        } finally {
            CloseHandle(process);
        }

        List<LineChatSummaryKeyCandidate> result = new List<LineChatSummaryKeyCandidate>();
        foreach (KeyValuePair<string, int> pair in counts) {
            result.Add(new LineChatSummaryKeyCandidate { Value = pair.Key, Frequency = pair.Value });
        }
        result.Sort(delegate(LineChatSummaryKeyCandidate a, LineChatSummaryKeyCandidate b) {
            int order = b.Frequency.CompareTo(a.Frequency);
            return order != 0 ? order : String.CompareOrdinal(a.Value, b.Value);
        });
        if (result.Count > maxCandidates) result.RemoveRange(maxCandidates, result.Count - maxCandidates);
        return result;
    }
}
'@
    }

    if ($Mode -ne 'ScanDbKeys') { throw '不支援的本機資料庫操作。' }
    $dbFolder = Join-Path $env:LOCALAPPDATA 'LINE\Data\db'
    if (-not (Test-Path -LiteralPath $dbFolder -PathType Container)) {
        throw '找不到 LINE 本機資料庫目錄。請確認已登入 Windows 桌面版 LINE。'
    }
    $dbFiles = @(Get-ChildItem -LiteralPath $dbFolder -File -Filter '*.edb' -ErrorAction Stop |
        Where-Object { $_.Name -notmatch '^(?i:keep_|chatStats_)' } |
        Sort-Object -Property Length -Descending)
    if ($dbFiles.Count -eq 0) { throw '找不到 LINE 聊天資料庫（.edb）。請確認 LINE 已登入並完成資料同步。' }

    $lineProcesses = @(Get-Process -Name 'LINE' -ErrorAction SilentlyContinue)
    if ($lineProcesses.Count -eq 0) { throw '找不到 LINE.exe。請先開啟並登入 LINE 桌面版。' }
    $allCandidates = New-Object 'System.Collections.Generic.Dictionary[string,int]'
    $scannedProcessCount = 0
    foreach ($process in $lineProcesses) {
        try {
            $candidates = [LineChatSummaryKeyScanner]::Scan([int]$process.Id, 4096)
            $scannedProcessCount++
        } catch {
            continue
        }
        foreach ($candidate in $candidates) {
            $frequency = 0
            $allCandidates.TryGetValue($candidate.Value, [ref]$frequency) | Out-Null
            $allCandidates[$candidate.Value] = $frequency + [int]$candidate.Frequency
        }
    }
    if ($scannedProcessCount -eq 0) {
        throw ('無法唯讀存取 LINE 程序記憶體（偵測到 {0} 個程序）；請確認 LINE 與工具以相同 Windows 使用者及權限執行。' -f $lineProcesses.Count)
    }
    $ordered = @($allCandidates.GetEnumerator() | Sort-Object -Property @{Expression={$_.Value};Descending=$true}, @{Expression={$_.Key};Descending=$false} | Select-Object -First 4096 | ForEach-Object {
        [pscustomobject]@{ value = $_.Key; frequency = $_.Value }
    })
    if ($ordered.Count -eq 0) { throw ('已掃描 {0} 個 LINE 程序，但沒有找到資料庫解鎖候選值。請確認 LINE 已登入後重新載入群組。' -f $scannedProcessCount) }

    $version = $null
    try { $version = (Get-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'LINE\bin\current\LINE.exe')).VersionInfo.ProductVersion } catch { }
    [pscustomobject]@{
        ok = $true
        databasePaths = @($dbFiles | ForEach-Object { $_.FullName })
        candidates = $ordered
        scannedProcessCount = $scannedProcessCount
        candidateCount = $ordered.Count
        lineVersion = $version
    } | ConvertTo-Json -Compress -Depth 4
} catch {
    [pscustomobject]@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress -Depth 3
    exit 1
}
