$ErrorActionPreference = 'Stop'
$runtimeDir = Join-Path $PSScriptRoot '夜航运行包'
$launcher = Join-Path $runtimeDir 'launch.mjs'
$offlinePage = Join-Path $runtimeDir '夜航模拟器.html'
$cacheDir = Join-Path $env:LOCALAPPDATA 'Nightflight'
$cachedNode = Join-Path $cacheDir 'node.exe'
$nodeVersion = '22.23.5'

function Test-Node($candidate) {
    if (!$candidate -or !(Test-Path -LiteralPath $candidate -PathType Leaf)) { return $false }
    try {
        # Old Node versions may print an error to stderr.
        $ErrorActionPreference = 'Continue'
        & $candidate --input-type=module -e 'process.exit(parseInt(process.versions.node,10) >= 22 && !!import.meta.dirname ? 0 : 1)' 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Install-Node {
    $cpu = $env:PROCESSOR_ARCHITEW6432
    if (!$cpu) { $cpu = $env:PROCESSOR_ARCHITECTURE }
    switch ($cpu) {
        'ARM64' { $arch = 'arm64'; $checksum = 'c1856817f611738c77534efbff8a5a17990593eab24046bc8d2c23a77a160d13' }
        'AMD64' { $arch = 'x64'; $checksum = '4a191082e9706866830379d577d2cc8a50c776fcd9436a8d061b063ed0d9a0e3' }
        'X86' { $arch = 'x86'; $checksum = '9c01245683c87e3f81eedfbad82c1665611749627cd1b0b5a42921db9361b4a6' }
        default { throw "暂不支持此处理器架构。$cpu" }
    }

    [void][IO.Directory]::CreateDirectory($cacheDir)
    $stage = Join-Path $cacheDir ([guid]::NewGuid().ToString())
    [void][IO.Directory]::CreateDirectory($stage)
    $package = "node-v$nodeVersion-win-$arch"
    $download = Join-Path $stage "$package.zip"
    $nodeExe = Join-Path $stage 'node.exe'
    try {
        Write-Host '正在下载 Node.js，首次配置需要联网……'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 600 -Uri "https://nodejs.org/dist/v$nodeVersion/$package.zip" -OutFile $download
        if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $checksum) {
            throw 'Node.js 下载文件校验失败。'
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($download)
        try {
            $entry = $zip.Entries | Where-Object { $_.Name -eq 'node.exe' } | Select-Object -First 1
            if (!$entry) { throw 'Node.js 下载包中缺少 node.exe。' }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $nodeExe)
        } finally {
            $zip.Dispose()
        }
        if (!(Test-Node $nodeExe)) { throw '下载的 Node.js 无法在这台电脑上运行。' }
        try {
            [IO.File]::Move($nodeExe, $cachedNode)
        } catch {
            # Another launcher may have published a usable copy while we were downloading.
            if (!(Test-Node $cachedNode)) {
                Remove-Item -LiteralPath $cachedNode -Force -ErrorAction SilentlyContinue
                [IO.File]::Move($nodeExe, $cachedNode)
            }
        }
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    if (!(Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw '找不到夜航运行包。请完整解压，并保留启动文件和夜航运行包的相对位置。'
    }
    $candidates = @(Get-Command node.exe -All -CommandType Application -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Source })
    foreach ($folder in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432)) {
        if ($folder) { $candidates += (Join-Path $folder 'nodejs\node.exe') }
    }
    $candidates += $cachedNode
    $node = $candidates | Where-Object { Test-Node $_ } | Select-Object -First 1
    if (!$node) {
        Install-Node
        $node = $cachedNode
    }

    $env:NIGHTFLIGHT_CACHE = $cacheDir
    & $node $launcher
    if ($LASTEXITCODE -in @(0, 130, -1073741510)) { exit 0 }
    throw "本地服务已退出（代码 $LASTEXITCODE）。"
} catch {
    Write-Host "夜航启动失败。$($_.Exception.Message)" -ForegroundColor Red
    if (Test-Path -LiteralPath $offlinePage -PathType Leaf) {
        Write-Host '正在打开离线版，可使用键盘或实体手柄。'
        Start-Process -FilePath $offlinePage
    }
    exit 1
}
