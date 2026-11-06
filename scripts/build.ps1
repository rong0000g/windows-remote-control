# Compiles every C# program with the .NET compiler built into Windows.
# Kept ASCII-only: Windows PowerShell 5.1 misreads UTF-8 scripts that have no BOM.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$net = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
$meta = "$env:WINDIR\System32\WinMetadata"

# csc fails with CS1619 when the temp path is too long, so use a short one.
$tmp = Join-Path ([IO.Path]::GetPathRoot($env:WINDIR)) 'rc-build-tmp'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:TEMP = $tmp
$env:TMP = $tmp

$winrt = @("$meta\Windows.Devices.winmd", "$meta\Windows.Foundation.winmd", "$meta\Windows.Storage.winmd",
    "$net\System.Runtime.dll", "$net\System.Threading.Tasks.dll", "$net\System.Runtime.InteropServices.WindowsRuntime.dll", "$net\System.Core.dll")
$forms = @("$net\System.Windows.Forms.dll", "$net\System.Drawing.dll", "$net\System.Core.dll")

$targets = @(
    @{ src = 'scripts\dictate.cs'; refs = @("$net\WPF\System.Speech.dll", "$net\System.Core.dll", "$net\System.Security.dll", "$net\System.Web.Extensions.dll", "$net\System.Windows.Forms.dll") },
    @{ src = 'tools\keylog.cs'; refs = $forms },
    @{ src = 'tools\voicecap.cs'; refs = $forms },
    @{ src = 'tools\wincap.cs'; refs = $forms },
    @{ src = 'tools\gattprobe.cs'; refs = $winrt + $forms },
    @{ src = 'tools\btscan.cs'; refs = $winrt }
)

foreach ($t in $targets) {
    $src = Join-Path $root $t.src
    $out = [IO.Path]::ChangeExtension($src, '.exe')
    $target = if ($t.src -like '*btscan*' -or $t.src -like '*wincap*') { '/target:exe' } else { '/target:winexe' }
    $cscArgs = @('/nologo', '/platform:x64', $target, '/codepage:65001', "/out:$out") + ($t.refs | ForEach-Object { "/r:$_" }) + @($src)
    & "$net\csc.exe" @cscArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Build failed: $($t.src)" }
    "Built $($t.src)"
}
