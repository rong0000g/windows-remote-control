# Downloads the local speech recognizer used by dictate.exe into scripts\asr.
# About 155 MB for the model archive and 18 MB for the runtime; about 270 MB once unpacked.
# Needs Python on PATH. The runtime is installed for that Python version, so rerun this after upgrading Python.
# Kept ASCII-only: Windows PowerShell 5.1 misreads UTF-8 scripts that have no BOM.
$ErrorActionPreference = 'Stop'
$asr = Join-Path $PSScriptRoot 'asr'
$name = 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17'
$url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$name.tar.bz2"
$archive = Join-Path $asr "$name.tar.bz2"

if (-not (Test-Path (Join-Path $asr "$name\model.int8.onnx"))) {
    "Downloading $name"
    & curl.exe -fSL --retry 3 -o $archive $url
    if ($LASTEXITCODE -ne 0) { throw 'Model download failed' }
    # Python rather than tar.exe, which hung on a path with non-ASCII characters.
    $unpack = 'import sys, tarfile; tarfile.open(sys.argv[1], "r:bz2").extractall(sys.argv[2], filter="data")'
    & python -I -c $unpack $archive $asr
    if ($LASTEXITCODE -ne 0) { throw 'Model unpack failed' }
    Remove-Item $archive
}

"Installing the recognizer runtime"
& python -I -m pip install --quiet --disable-pip-version-check --upgrade --target (Join-Path $asr 'pylib') 'sherpa-onnx==2.0.1'
if ($LASTEXITCODE -ne 0) { throw 'Runtime install failed' }
"Done"
