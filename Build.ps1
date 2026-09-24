$ErrorActionPreference = 'Stop'

$packageRoot = $PSScriptRoot
$outputsRoot = Split-Path -Parent $packageRoot
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$runtimeZip = Join-Path $packageRoot 'LineChatSummary.DbRuntime.zip'
$exePath = Join-Path $packageRoot 'LineChatSummary.exe'
$distExe = Join-Path $outputsRoot 'LineChatSummary.exe'
$sourceZip = Join-Path $outputsRoot 'LineChatSummary-2.5.2.zip'

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

Copy-Item -LiteralPath $exePath -Destination $distExe -Force
Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $sourceZip -Force -CompressionLevel Optimal

Write-Output "EXE: $distExe"
Write-Output "維護套件: $sourceZip"
