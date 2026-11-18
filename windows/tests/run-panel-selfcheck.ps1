param([Parameter(Mandatory=$true)][string]$BuildRoot)
# 仅离屏自检；不注册输入法、不启动宿主、不注入按键。
$ErrorActionPreference = 'Stop'
$originalFont = $env:GOGAKU_PANEL_FONT
try {
    if (-not $env:GOGAKU_PANEL_FONT) {
        $env:GOGAKU_PANEL_FONT = Join-Path $env:WINDIR 'Fonts\msyh.ttc'
        if (-not (Test-Path $env:GOGAKU_PANEL_FONT)) {
            $env:GOGAKU_PANEL_FONT = Join-Path $env:WINDIR 'Fonts\segoeui.ttf'
        }
    }
    $failed = $false
    foreach ($arch in @('x64', 'x86')) {
        foreach ($test in @('gogaku_core_panel_render_test', 'gogaku_windows_appearance_test')) {
            $exe = Join-Path $BuildRoot "tests\$arch\$test.exe"
            if (-not (Test-Path $exe)) { throw "Missing self-check: $exe" }
            Write-Output "$arch / $test"
            & $exe
            if ($LASTEXITCODE -ne 0) { $failed = $true }
        }
    }
    if ($failed) { exit 1 }
} finally {
    $env:GOGAKU_PANEL_FONT = $originalFont
}
