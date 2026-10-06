param([string]$GamePath = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
try {
    $root = (Resolve-Path -LiteralPath $GamePath).Path.TrimEnd('\')
    if (Get-Process Sudeki,SudekiLauncher -ErrorAction SilentlyContinue) { throw 'Once oyunu ve baslaticiyi kapatin.' }
    $backup = Join-Path $root 'SudekiTR_Yedek_03'
    $manifest = Get-Content -LiteralPath (Join-Path $backup 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    function Target([string]$base,[string]$relative) {
        $full = [IO.Path]::GetFullPath((Join-Path $base $relative))
        if (!$full.StartsWith($base.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Gecersiz yol.' }
        return $full
    }
    function Hash([string]$path) {
        $stream = [IO.File]::OpenRead($path); $algorithm = [Security.Cryptography.SHA256]::Create()
        try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
        finally { $stream.Dispose(); $algorithm.Dispose() }
    }
    foreach ($item in $manifest.files) {
        if ((Hash (Target $backup $item.path)) -ne $item.original) { throw "Yedek bozuk veya eksik: $($item.path)" }
    }
    if ((Hash (Join-Path $backup 'binkw32.dll')) -ne $manifest.original_decoder_sha256) { throw 'Oynatici yedegi bozuk.' }
    foreach ($item in $manifest.files) { [IO.File]::Copy((Target $backup $item.path),(Target $root $item.path),$true) }
    [IO.File]::Copy((Join-Path $backup 'binkw32.dll'),(Join-Path $root 'binkw32.dll'),$true)
    foreach ($item in $manifest.added) {
        if ($item.path -eq 'binkw32.dll') { continue }
        $file = Target $root $item.path
        if (Test-Path -LiteralPath $file) { [IO.File]::Delete($file) }
    }
    $sidecar = Join-Path $root 'binkw32_original.dll'
    if (Test-Path -LiteralPath $sidecar) { [IO.File]::Delete($sidecar) }
    # Remove only empty directories; any user-added files remain intact.
    foreach ($relative in @('SudekiTR\Video','SudekiTR')) {
        $dir = Target $root $relative
        if ((Test-Path -LiteralPath $dir) -and @(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0) { [IO.Directory]::Delete($dir,$false) }
    }
    Write-Host 'YAMA KALDIRILDI. Ozgun dosyalar geri yuklendi. Yedek klasoru korundu.'
} catch { Write-Host ('HATA: '+$_.Exception.Message) -ForegroundColor Red; exit 1 }
