$ErrorActionPreference = 'Stop'

$packageRoot = $PSScriptRoot
$outputsRoot = Split-Path -Parent $packageRoot
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$runtimeZip = Join-Path $packageRoot 'LineChatSummary.DbRuntime.zip'
$exePath = Join-Path $packageRoot 'LineChatSummary.exe'
$launcherExe = Join-Path $packageRoot 'LineChatSummary-Codex.exe'
$sourceZip = Join-Path $outputsRoot 'LineChatSummary-Codex-Complete.zip'

if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw "找不到 .NET Framework C# 編譯器：$compiler"
}
if (-not (Test-Path -LiteralPath $runtimeZip -PathType Leaf)) {
    throw "找不到資料庫原生元件：$runtimeZip"
}

$dbScript = Join-Path $packageRoot 'LineChatSummaryDb.ps1'
$dbScriptText = [System.IO.File]::ReadAllText($dbScript, [System.Text.Encoding]::UTF8)
$utf8WithBom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($dbScript, $dbScriptText, $utf8WithBom)

$resources = @(
    'LineChatSummary.ps1,LineChatSummary.ps1',
    'LineChatSummaryDb.ps1,LineChatSummary.DbScript',
    'server.js,LineChatSummary.server.js',
    'line-db.js,LineChatSummary.line-db.js',
    'line-chat-summary-preview.html,LineChatSummary.index.html',
    'LineChatSummary.DbRuntime.zip,LineChatSummary.DbRuntime'
)

$arguments = @(
    '/nologo',
    '/target:winexe',
    '/platform:x64',
    '/optimize+',
    '/out:LineChatSummary.exe',
    '/reference:System.Windows.Forms.dll',
    '/reference:System.Drawing.dll',
    '/reference:System.IO.Compression.dll',
    '/reference:System.IO.Compression.FileSystem.dll'
)
foreach ($resource in $resources) { $arguments += "/resource:$resource" }
$arguments += 'Launcher.cs'

Push-Location $packageRoot
try {
    & $compiler @arguments
    if ($LASTEXITCODE -ne 0) { throw "EXE 編譯失敗，csc.exe 結束碼：$LASTEXITCODE" }
}
finally {
    Pop-Location
}

$setupArguments = @(
    '/nologo',
    '/target:winexe',
    '/platform:x64',
    '/optimize+',
    '/out:LineChatSummary-Codex.exe',
    '/reference:System.Windows.Forms.dll',
    '/reference:System.Drawing.dll',
    '/reference:System.IO.Compression.dll',
    '/reference:System.IO.Compression.FileSystem.dll',
    '/resource:LineChatSummary.exe,LineChatSummary.App',
    'SetupLauncher.cs'
)

Push-Location $packageRoot
try {
    & $compiler @setupArguments
    if ($LASTEXITCODE -ne 0) { throw "安裝程式編譯失敗，csc.exe 結束碼：$LASTEXITCODE" }
}
finally {
    Pop-Location
}

if (Test-Path -LiteralPath $exePath) { Remove-Item -LiteralPath $exePath -Force }
foreach ($duplicate in @('Setting.exe','LineChatSummary-Setup.exe','LineChatSummary-Setting.exe')) {
    $duplicatePath = Join-Path $packageRoot $duplicate
    if (Test-Path -LiteralPath $duplicatePath) { Remove-Item -LiteralPath $duplicatePath -Force }
}
Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $sourceZip -Force -CompressionLevel Optimal

Write-Output "唯一執行檔（首次安裝／之後啟動）: $launcherExe"
Write-Output "維護套件: $sourceZip"
