$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$WebRoot = Join-Path $Root 'clients\app\build\web'
$Index = Join-Path $WebRoot 'index.html'
if (-not (Test-Path -LiteralPath $Index)) {
    throw "DD Web Release 不存在：$Index`n请先在 clients\app 执行 flutter build web --release。"
}

$python = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $python) {
    $python = Get-Command python -ErrorAction SilentlyContinue
}
if ($null -eq $python) {
    throw '未找到 Python，无法启动 DD Web 本地静态服务器。'
}

$probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$probe.Start()
$port = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
$probe.Stop()
if ($port -lt 10000) {
    # 极低概率系统分配到 5 位数以下端口时，重新选择产品约定的 5 位数端口。
    $port = Get-Random -Minimum 20000 -Maximum 60000
}

$arguments = @(
    '-m', 'http.server', $port,
    '--bind', '127.0.0.1',
    '--directory', $WebRoot
)
$process = Start-Process -FilePath $python.Source -ArgumentList $arguments -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 500
if ($process.HasExited) {
    throw 'DD Web 静态服务器启动失败。'
}

$url = "http://127.0.0.1:$port/"
Start-Process $url
Write-Host "DD_WEB_URL=$url"
Write-Host "DD_WEB_SERVER_PID=$($process.Id)"
