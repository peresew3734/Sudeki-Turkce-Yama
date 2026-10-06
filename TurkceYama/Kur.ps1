param([string]$GamePath = (Split-Path -Parent $PSScriptRoot), [switch]$VerifyOnly)
$ErrorActionPreference = 'Stop'
try {
    $root = (Resolve-Path -LiteralPath $GamePath).Path.TrimEnd('\')
    if (!$VerifyOnly -and !(Test-Path -LiteralPath (Join-Path $root 'Sudeki.exe'))) { throw 'Sudeki.exe bulunamadi. Yama paketinin icindekileri Sudeki.exe bulunan oyun klasorune kopyalayin.' }
    if (Get-Process Sudeki,SudekiLauncher -ErrorAction SilentlyContinue) { throw 'Once oyunu ve baslaticiyi tamamen kapatin.' }
    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    function Target([string]$base,[string]$relative) {
        $full = [IO.Path]::GetFullPath((Join-Path $base $relative))
        if (!$full.StartsWith($base.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Gecersiz paket yolu.' }
        return $full
    }
    function Hash([string]$path) {
        $stream = [IO.File]::OpenRead($path); $algorithm = [Security.Cryptography.SHA256]::Create()
        try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
        finally { $stream.Dispose(); $algorithm.Dispose() }
    }
    $backup = Join-Path $root 'SudekiTR_Yedek_03'
    if (!$VerifyOnly) {
        foreach ($name in @('SudekiTR','binkw32_original.dll','SudekiTR_Yedek_03')) {
            if (Test-Path -LiteralPath (Join-Path $root $name)) { throw "Mevcut yama veya yedek bulundu: $name. Once onceki yamayi geri alin; yedegi guvenli bir yere tasiyin." }
        }
    }
    Write-Host 'Oyun surumu ve paket butunlugu kontrol ediliyor...'
    foreach ($item in $manifest.files) {
        if ((Hash (Target $root $item.path)) -ne $item.original) { throw "Ozgun dosya/surum uyusmuyor: $($item.path). Steam dosya dogrulamasi yapin ve Ingilizce surumu kullanin." }
        if ((Hash (Target $PSScriptRoot $item.patch)) -ne $item.patch_sha256) { throw "Yama dosyasi bozuk: $($item.patch)" }
    }
    $decoder = Join-Path $root 'binkw32.dll'
    if ((Hash $decoder) -ne $manifest.original_decoder_sha256) { throw 'Ozgun binkw32.dll uyusmuyor. Once eski yamayi geri alin.' }
    foreach ($item in $manifest.added) {
        if ((Hash (Target (Join-Path $PSScriptRoot 'payload') $item.path)) -ne $item.sha256) { throw "Paket dosyasi bozuk: $($item.path)" }
    }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;
public static class SudekiDelta {
 public static void Apply(string original,string patch,string output) {
  using(var src=File.OpenRead(original)) using(var packed=File.OpenRead(patch))
  using(var zip=new GZipStream(packed,CompressionMode.Decompress)) using(var r=new BinaryReader(zip))
  using(var dst=new FileStream(output,FileMode.CreateNew,FileAccess.Write)) {
   if(new string(r.ReadChars(4))!="STR1") throw new Exception("Bad patch header");
   long expected=r.ReadInt64();byte[] buffer=new byte[131072];
   while(true) {
    byte op=r.ReadByte();if(op==255)break;
    long offset=0;uint count;
    if(op==0){offset=r.ReadInt64();count=r.ReadUInt32();if(offset<0||offset+count>src.Length)throw new Exception("Copy bounds");src.Position=offset;}
    else if(op==1)count=r.ReadUInt32();else throw new Exception("Bad opcode");
    if(dst.Length+count>expected)throw new Exception("Output bounds");
    while(count>0){int want=(int)Math.Min(count,(uint)buffer.Length);int n=op==0?src.Read(buffer,0,want):r.Read(buffer,0,want);if(n==0)throw new EndOfStreamException();dst.Write(buffer,0,n);count-=(uint)n;}
   }
   if(dst.Length!=expected)throw new Exception("Output length mismatch");
  }
 }
}
'@
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('SudekiTR_'+[Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage)
    $staged = @()
    try {
        $index = 0
        foreach ($item in $manifest.files) {
            Write-Host "Hazirlaniyor: $($item.path)"
            $output = Join-Path $stage ([string]$index+'.bin'); $index++
            $staged += $output
            [SudekiDelta]::Apply((Target $root $item.path),(Target $PSScriptRoot $item.patch),$output)
            if ((Hash $output) -ne $item.patched) { throw "Uretilen dosya dogrulanamadi: $($item.path)" }
        }
        if ($VerifyOnly) { Write-Host 'DOGRULAMA BASARILI. Oyun dosyalarina yazilmadi.'; return }
        # All outputs and payloads are verified before any installed file changes.
        [void][IO.Directory]::CreateDirectory($backup)
        foreach ($item in $manifest.files) {
            $dest = Target $backup $item.path
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))
            [IO.File]::Copy((Target $root $item.path),$dest,$false)
            if ((Hash $dest) -ne $item.original) { throw 'Yedek dogrulanamadi.' }
        }
        [IO.File]::Copy($decoder,(Join-Path $backup 'binkw32.dll'),$false)
        if ((Hash (Join-Path $backup 'binkw32.dll')) -ne $manifest.original_decoder_sha256) { throw 'Oynatici yedegi dogrulanamadi.' }
        [IO.File]::Copy((Join-Path $PSScriptRoot 'manifest.json'),(Join-Path $backup 'manifest.json'),$false)
        [IO.File]::Copy((Join-Path $PSScriptRoot 'Kaldir.ps1'),(Join-Path $backup 'Kaldir.ps1'),$false)
        $restoreCommand = @(
            '@echo off'
            'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Kaldir.ps1"'
            'set "SUDEKI_YAMA_EXIT=%ERRORLEVEL%"'
            'pause'
            'exit /b %SUDEKI_YAMA_EXIT%'
        )
        [IO.File]::WriteAllLines((Join-Path $backup 'GERI_YUKLE.cmd'),$restoreCommand,[Text.Encoding]::ASCII)
        try {
            for ($i=0;$i -lt $manifest.files.Count;$i++) { [IO.File]::Copy($staged[$i],(Target $root $manifest.files[$i].path),$true) }
            [IO.File]::Copy((Join-Path $backup 'binkw32.dll'),(Join-Path $root 'binkw32_original.dll'),$false)
            foreach ($item in $manifest.added) {
                $dest = Target $root $item.path
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))
                [IO.File]::Copy((Target (Join-Path $PSScriptRoot 'payload') $item.path),$dest,$true)
                if ((Hash $dest) -ne $item.sha256) { throw 'Kurulan dosya dogrulanamadi.' }
            }
            foreach ($item in $manifest.files) { if ((Hash (Target $root $item.path)) -ne $item.patched) { throw 'Kurulum dogrulanamadi.' } }
        } catch {
            Write-Host 'Kurulum tamamlanamadi; ozgun dosyalar geri yukleniyor.'
            & (Join-Path $backup 'Kaldir.ps1') -GamePath $root
            throw
        }
        Write-Host 'TURKCE YAMA KURULDU.' -ForegroundColor Green
        Write-Host 'Steam dili Ingilizce, oyun altyazilari acik olsun.'
        Write-Host "Ozgun dosya yedegi: $backup"
        Write-Host 'Geri almak icin yedek klasorundeki GERI_YUKLE.cmd dosyasini calistirin.'
    } finally {
        foreach ($file in $staged) { if (Test-Path -LiteralPath $file) { [IO.File]::Delete($file) } }
        if ($stage -and (Test-Path -LiteralPath $stage)) { [IO.Directory]::Delete($stage,$false) }
    }
} catch { Write-Host ('HATA: '+$_.Exception.Message) -ForegroundColor Red; exit 1 }
