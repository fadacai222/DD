$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$ServerPath = Join-Path $Root 'server'
$DartClientPath = Join-Path $Root 'clients\realtime_poc'

& docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'Docker Desktop is not running. Start it and rerun this script.'
}

Write-Host '[1/3] Go format, vet, and tests'
& docker run --rm `
    --mount "type=bind,source=$ServerPath,target=/src,readonly" `
    -w /tmp `
    golang:1.26.5-alpine `
    sh -lc 'cp -R /src ./server && cd server && test -z "$(gofmt -l .)" && go vet ./... && go test ./...'
if ($LASTEXITCODE -ne 0) { throw 'Go checks failed.' }

Write-Host '[2/3] Dart format, analyze, and tests'
& docker run --rm `
    --mount "type=bind,source=$DartClientPath,target=/src,readonly" `
    -w /tmp `
    dart:3.12.2 `
    sh -lc 'cp -R /src ./client && cd client && dart pub get && dart format --output=none --set-exit-if-changed . && dart analyze && dart test'
if ($LASTEXITCODE -ne 0) { throw 'Dart checks failed.' }

Write-Host '[3/3] Build server image'
& docker build --build-arg VERSION=0.1.0-poc -t selfhosted-im/realtime-api:0.1.0-poc $ServerPath
if ($LASTEXITCODE -ne 0) { throw 'Docker image build failed.' }

Write-Host 'All PoC checks passed.'
