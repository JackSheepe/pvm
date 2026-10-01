#Requires -Version 5.1
<#
.SYNOPSIS
    PVM v3.0 — PHP Version Manager for XAMPP (nvm-style)
.DESCRIPTION
    Скачивает, устанавливает и переключает версии PHP в XAMPP.
    Автоматически подбирает совместимый Apache, ставит curl-зависимости,
    делает бэкапы и откатывает при сбое.
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Command = "help",
    [Parameter(Position=1, ValueFromRemainingArguments=$true)][string[]]$Arguments = @()
)

$ErrorActionPreference = "Stop"
$script:PVM_VERSION  = "3.0.0"
$script:YES          = $false
$script:DRY_RUN      = $false
$script:NO_BACKUP    = $false
$script:KEEP_BACKUPS = 10

# Unix-style aliases
if ($Command -eq '-l' -or $Command -eq '--list')    { $Command = 'list' }
if ($Command -eq '-h' -or $Command -eq '--help')    { $Command = 'help' }
if ($Command -eq '-v' -or $Command -eq '--version') { Write-Host "pvm v$($script:PVM_VERSION)"; exit 0 }

$filtered = @()
foreach ($a in $Arguments) {
    switch -Regex ($a.ToLower()) {
        '^(-y|--yes)$'           { $script:YES = $true;       continue }
        '^--dry-run$'            { $script:DRY_RUN = $true;   continue }
        '^--no-backup$'          { $script:NO_BACKUP = $true; continue }
        '^--keep-backups=(\d+)$' { $script:KEEP_BACKUPS = [int]$Matches[1]; continue }
        default                  { $filtered += $a }
    }
}
$Arguments = $filtered

# ============ PATHS ============
$script:PVM_HOME     = if ($env:PVM_HOME) { $env:PVM_HOME } else { Join-Path $env:USERPROFILE ".pvm" }
$script:VERSIONS_DIR = Join-Path $PVM_HOME "versions"
$script:PMA_DIR      = Join-Path $PVM_HOME "phpmyadmin"
$script:CACHE_DIR    = Join-Path $PVM_HOME "cache"
$script:BACKUP_DIR   = Join-Path $PVM_HOME "backups"
$script:CONFIG_FILE  = Join-Path $PVM_HOME "config.json"
$script:LOCK_FILE    = Join-Path $PVM_HOME "pvm.lock"
$script:XAMPP_DIR    = $null
$script:APACHE_SERVICE = $null

# ============ LOGGING ============
function Write-Info    { param($m) Write-Host "pvm: " -F Cyan   -NoNewline; Write-Host $m }
function Write-Success { param($m) Write-Host "pvm: " -F Green  -NoNewline; Write-Host $m }
function Write-Warn    { param($m) Write-Host "pvm: " -F Yellow -NoNewline; Write-Host $m }
function Write-Err     { param($m) Write-Host "pvm: " -F Red    -NoNewline; Write-Host $m }

function Ensure-Dirs {
    foreach ($d in @($PVM_HOME,$VERSIONS_DIR,$PMA_DIR,$CACHE_DIR,$BACKUP_DIR)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

function Confirm-Action {
    param([string]$Message, [switch]$DefaultYes)
    if ($script:YES) { return $true }
    if ($script:DRY_RUN) { return $true }
    $hint = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    $ans = Read-Host "$Message $hint"
    if ([string]::IsNullOrWhiteSpace($ans)) { return [bool]$DefaultYes }
    return ($ans -match '^(y|yes|д|да)$')
}

# ============ LOCK ============
function Enter-Lock {
    Ensure-Dirs
    if (Test-Path $LOCK_FILE) {
        try {
            $data = Get-Content $LOCK_FILE -Raw | ConvertFrom-Json
            if (Get-Process -Id $data.Pid -ErrorAction SilentlyContinue) {
                Write-Err "Другой pvm уже работает (PID $($data.Pid))."
                throw "locked"
            }
        } catch {}
        Remove-Item $LOCK_FILE -Force -ErrorAction SilentlyContinue
    }
    @{ Pid = $PID; Started = (Get-Date).ToString("o") } |
        ConvertTo-Json | Set-Content $LOCK_FILE -Encoding UTF8
}
function Exit-Lock { Remove-Item $LOCK_FILE -Force -ErrorAction SilentlyContinue }

# ============ XAMPP / APACHE ============
function Find-Xampp {
    foreach ($c in @("C:\xampp","D:\xampp","$env:SystemDrive\xampp","C:\Program Files\xampp")) {
        if ($c -and (Test-Path (Join-Path $c "apache\bin\httpd.exe"))) { return $c }
    }
    $procs = Get-Process httpd -ErrorAction SilentlyContinue
    if ($procs) {
        $p = $procs[0].Path
        if ($p -match "^(.*)\\apache\\bin\\httpd\.exe$") { return $Matches[1] }
    }
    return $null
}
function Find-ApacheService {
    $svc = Get-Service -Name "Apache2.4" -ErrorAction SilentlyContinue
    if ($svc) { return "Apache2.4" }
    $svc = Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "Apache*" } | Select-Object -First 1
    if ($svc) { return $svc.Name }
    return $null
}
function Load-Config {
    Ensure-Dirs
    if (Test-Path $CONFIG_FILE) {
        try {
            $cfg = Get-Content $CONFIG_FILE -Raw | ConvertFrom-Json
            if ($cfg.xamppDir)      { $script:XAMPP_DIR      = [string]$cfg.xamppDir }
            if ($cfg.apacheService) { $script:APACHE_SERVICE = [string]$cfg.apacheService }
            if ($cfg.keepBackups)   { $script:KEEP_BACKUPS   = [int]$cfg.keepBackups }
        } catch {}
    }
    if (-not $script:XAMPP_DIR) { $script:XAMPP_DIR = Find-Xampp }
    if ($script:XAMPP_DIR -and -not $script:APACHE_SERVICE) {
        $script:APACHE_SERVICE = Find-ApacheService
    }
}
function Save-Config {
    [PSCustomObject]@{
        xamppDir      = $script:XAMPP_DIR
        apacheService = $script:APACHE_SERVICE
        keepBackups   = $script:KEEP_BACKUPS
    } | ConvertTo-Json | Set-Content $CONFIG_FILE -Encoding UTF8
}

function Stop-Apache {
    if ($script:DRY_RUN) { Write-Info "[dry-run] Stop Apache"; return }
    if ($script:APACHE_SERVICE) {
        $svc = Get-Service $script:APACHE_SERVICE -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") {
            Write-Info "Останавливаю службу $script:APACHE_SERVICE..."
            try { Stop-Service $script:APACHE_SERVICE -Force -ErrorAction Stop }
            catch { Write-Warn "Не удалось остановить: $_" }
        }
    }
    Get-Process httpd -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
}
function Test-ApacheHealth {
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            Invoke-WebRequest -Uri "http://127.0.0.1/" -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop | Out-Null
            return $true
        } catch {
            if ($_.Exception.Response) { return $true }
        }
    }
    return [bool](Get-Process httpd -ErrorAction SilentlyContinue)
}
function Start-Apache {
    if ($script:DRY_RUN) { Write-Info "[dry-run] Start Apache"; return $true }
    if ($script:APACHE_SERVICE) {
        $svc = Get-Service $script:APACHE_SERVICE -ErrorAction SilentlyContinue
        if ($svc) {
            Write-Info "Запускаю службу $script:APACHE_SERVICE..."
            try { Start-Service $script:APACHE_SERVICE -ErrorAction Stop }
            catch { Write-Warn "Не удалось запустить: $_" }
            return (Test-ApacheHealth)
        }
    }
    $httpd = Join-Path $script:XAMPP_DIR "apache\bin\httpd.exe"
    if (Test-Path $httpd) { Start-Process $httpd -WindowStyle Hidden }
    return (Test-ApacheHealth)
}

# ============ JUNCTION ============
function Remove-Link {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    $item = Get-Item $Path -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType) { cmd /c "rmdir `"$Path`"" 2>$null | Out-Null }
    else { Remove-Item $Path -Recurse -Force }
}
function Create-Junction {
    param([string]$Link, [string]$Target)
    $parent = Split-Path $Link -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Remove-Link $Link
    $out = cmd /c "mklink /J `"$Link`" `"$Target`"" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "mklink failed: $out" }
}
function Get-LinkTarget {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $item = Get-Item $Path -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType -and $item.Target) {
        $t = $item.Target; if ($t -is [array]) { $t = $t[0] }
        return [string]$t
    }
    return $null
}

# ============ PHP VERSIONS ============
function Get-RemoteVersions {
    param([switch]$Force)
    $cacheFile = Join-Path $CACHE_DIR "php-remote.json"
    if (-not $Force -and (Test-Path $cacheFile)) {
        $age = (Get-Date) - (Get-Item $cacheFile).LastWriteTime
        if ($age.TotalHours -lt 6) {
            try {
                $cached = Get-Content $cacheFile -Raw | ConvertFrom-Json
                if ($cached) { return @($cached) }
            } catch {}
        }
    }
    Write-Info "Получение списка версий PHP..."
    $list = New-Object System.Collections.ArrayList
    foreach ($base in @(
        "https://windows.php.net/downloads/releases/",
        "https://windows.php.net/downloads/releases/archives/"
    )) {
        try {
            $html = [string](Invoke-WebRequest -Uri $base -UseBasicParsing -TimeoutSec 30).Content
            $rx = [regex]'href="(php-(\d+\.\d+\.\d+)-Win32-(vs\d+|vc\d+)-x64\.zip)"'
            foreach ($m in $rx.Matches($html)) {
                [void]$list.Add([PSCustomObject]@{
                    Version  = [string]$m.Groups[2].Value
                    FileName = [string]$m.Groups[1].Value
                    Url      = [string]($base + $m.Groups[1].Value)
                })
            }
        } catch { Write-Warn "Не удалось получить $base : $_" }
    }
    $seen = @{}; $unique = @()
    foreach ($item in $list) {
        $v = [string]$item.Version
        if (-not $seen.ContainsKey($v)) { $seen[$v] = $true; $unique += $item }
    }
    if ($unique.Count -gt 0) {
        $unique = @($unique | Sort-Object { [version]$_.Version })
        try { $unique | ConvertTo-Json | Set-Content -Path $cacheFile -Encoding UTF8 } catch {}
    }
    return @($unique)
}

function Get-InstalledVersions {
    if (-not (Test-Path $VERSIONS_DIR)) { return @() }
    @(Get-ChildItem $VERSIONS_DIR -Directory | ForEach-Object {
        [PSCustomObject]@{ Version = $_.Name; Path = $_.FullName }
    })
}

function Get-ActiveVersion {
    if (-not $script:XAMPP_DIR) { return $null }
    $phpPath = Join-Path $script:XAMPP_DIR "php"
    if (-not (Test-Path $phpPath)) { return $null }
    $t = Get-LinkTarget $phpPath
    if ($t) { return Split-Path $t -Leaf }
    return "unknown"
}

# ============ COMPILER / COMPATIBILITY ============
$script:PhpCompilerMap = @{
    '8.4' = 'VS17'
    '8.3' = 'VS16'; '8.2' = 'VS16'; '8.1' = 'VS16'; '8.0' = 'VS16'
    '7.4' = 'VC15'
    '7.3' = 'VC14'; '7.2' = 'VC14'; '7.1' = 'VC14'; '7.0' = 'VC14'
}
$script:CompilerRank = @{
    'VC6'=1; 'VC9'=2; 'VC11'=3; 'VC14'=4; 'VC15'=5; 'VS16'=6; 'VS17'=7; 'VS18'=8
}
$script:ApacheCatalogUrl = @{
    'VS18' = 'https://www.apachelounge.com/download/VS18/'
    'VS17' = 'https://www.apachelounge.com/download/VS17/'
    'VS16' = 'https://www.apachelounge.com/download/VS16/'
    'VC15' = 'https://www.apachelounge.com/download/VC15/'
    'VC14' = 'https://www.apachelounge.com/download/VC14/'
}

function Get-ApacheCompiler {
    if (-not $script:XAMPP_DIR) { return $null }
    $httpd = Join-Path $script:XAMPP_DIR "apache\bin\httpd.exe"
    if (-not (Test-Path $httpd)) { return $null }
    $out = (& $httpd -v 2>&1 | Out-String)
    if ($out -match '\bVC(\d+)\b') { return "VC$($Matches[1])" }
    if ($out -match '\bVS(\d+)\b') { return "VS$($Matches[1])" }
    return $null
}
function Get-PhpRequiredCompiler {
    param([string]$Version)
    if ($Version -match '^(\d+\.\d+)') {
        $mm = $Matches[1]
        if ($script:PhpCompilerMap.ContainsKey($mm)) { return $script:PhpCompilerMap[$mm] }
    }
    return $null
}
function Test-ApachePhpCompatibility {
    param([string]$PhpVersion)
    $apache   = Get-ApacheCompiler
    $required = Get-PhpRequiredCompiler -Version $PhpVersion
    if (-not $apache -or -not $required) { return $true }
    $rA = if ($script:CompilerRank.ContainsKey($apache))   { $script:CompilerRank[$apache] }   else { 0 }
    $rP = if ($script:CompilerRank.ContainsKey($required)) { $script:CompilerRank[$required] } else { 0 }
    return ($rA -ge $rP)
}

# ============ APACHE DOWNLOAD ============
function Test-IsZipFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    if ((Get-Item $Path).Length -lt 1MB) { return $false }
    $b = [System.IO.File]::ReadAllBytes($Path)[0..3]
    return ($b[0] -eq 0x50 -and $b[1] -eq 0x4B -and $b[2] -eq 0x03 -and $b[3] -eq 0x04)
}

function Get-ApacheDownloadUrls {
    param([string]$Compiler, [switch]$Force)
    if (-not $script:ApacheCatalogUrl.ContainsKey($Compiler)) { return @() }
    $cacheFile = Join-Path $CACHE_DIR "apache-urls-$Compiler.json"
    if (-not $Force -and (Test-Path $cacheFile)) {
        $age = (Get-Date) - (Get-Item $cacheFile).LastWriteTime
        if ($age.TotalHours -lt 6) {
            try {
                $cached = @(Get-Content $cacheFile -Raw | ConvertFrom-Json)
                if ($cached.Count -gt 0) { return $cached }
            } catch {}
        }
    }
    $pageUrl = $script:ApacheCatalogUrl[$Compiler]
    Write-Info "Поиск $Compiler на apachelounge.com..."
    $list = New-Object System.Collections.ArrayList
    foreach ($page in @($pageUrl, 'https://www.apachelounge.com/download/')) {
        try {
            $html = [string](Invoke-WebRequest -Uri $page -UseBasicParsing `
                -UserAgent 'Mozilla/5.0 (pvm)' -TimeoutSec 30).Content
        } catch { continue }
        $rx = [regex]'(?i)href="([^"]*httpd-2\.4\.\d+-[^"]*win64[^"]*\.zip)"'
        foreach ($m in $rx.Matches($html)) {
            $rel = $m.Groups[1].Value
            if ($rel -notmatch [regex]::Escape($Compiler)) { continue }
            $url = if ($rel -match '^https?://') { $rel }
                   elseif ($rel.StartsWith('/')) { 'https://www.apachelounge.com' + $rel }
                   else { 'https://www.apachelounge.com/' + $rel }
            if ($list -notcontains $url) { [void]$list.Add($url) }
        }
        if ($list.Count -gt 0) { break }
    }
    $sorted = @($list | Sort-Object -Property @{
        Expression = { if ($_ -match 'httpd-2\.4\.(\d+)-') { [int]$Matches[1] } else { 0 } }
    } -Descending)
    try { $sorted | ConvertTo-Json | Set-Content $cacheFile -Encoding UTF8 } catch {}
    return $sorted
}

function Install-ApacheForCompiler {
    param([string]$Compiler)
    $cur = Get-ApacheCompiler
    Write-Warn "Apache $cur несовместим — нужен $Compiler."
    if (-not (Confirm-Action "Скачать Apache $Compiler? Старый будет в бэкап." -DefaultYes)) { return $false }

    Stop-Apache
    $tmp = Join-Path $env:TEMP "pvm-apache-$(Get-Date -Format yyyyMMdd-HHmmss)"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $zip = Join-Path $tmp "apache.zip"

    $urls = Get-ApacheDownloadUrls -Compiler $Compiler
    if ($urls.Count -eq 0) {
        Write-Err "Не нашёл ссылок на Apache $Compiler."
        Write-Info "Скачайте вручную: $($script:ApacheCatalogUrl[$Compiler])"
        Write-Info "Положите сюда: $zip"
        return $false
    }

    Write-Info "Найдено: $($urls.Count)"
    $ok = $false
    foreach ($url in $urls) {
        Write-Info "Пробую: $url"
        try { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -UserAgent 'Mozilla/5.0 (pvm)' -TimeoutSec 300 }
        catch { Write-Warn "  ошибка: $($_.Exception.Message)"; continue }
        if (Test-IsZipFile $zip) { Write-Success "  OK"; $ok = $true; break }
    }
    if (-not $ok) { Write-Err "Скачать не удалось."; return $false }

    Write-Info "Распаковка..."
    try { Expand-Archive -Path $zip -DestinationPath $tmp -Force }
    catch { & tar.exe -xf $zip -C $tmp 2>&1 | Out-Null }

    $src = Get-ChildItem $tmp -Directory | Where-Object { $_.Name -like 'Apache*' } | Select-Object -First 1
    if (-not $src) { Write-Err "Apache24 не найден."; return $false }

    $ts  = Get-Date -Format yyyyMMdd-HHmmss
    $bak = Join-Path $script:PVM_HOME "backups\apache-$cur-to-$Compiler-$ts"
    New-Item -ItemType Directory -Path $bak -Force | Out-Null
    Write-Info "Бэкап: $bak"
    robocopy (Join-Path $script:XAMPP_DIR 'apache\bin')     "$bak\bin"     /MIR /NFL /NDL /NJH /NJS | Out-Null
    robocopy (Join-Path $script:XAMPP_DIR 'apache\modules') "$bak\modules" /MIR /NFL /NDL /NJH /NJS | Out-Null

    robocopy "$($src.FullName)\bin"     (Join-Path $script:XAMPP_DIR 'apache\bin')     /MIR /NFL /NDL /NJH /NJS | Out-Null
    robocopy "$($src.FullName)\modules" (Join-Path $script:XAMPP_DIR 'apache\modules') /MIR /NFL /NDL /NJH /NJS | Out-Null
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

    # Комментировать отсутствующие модули
    $conf = Join-Path $script:XAMPP_DIR "apache\conf\httpd.conf"
    if (Test-Path $conf) {
        $modDir = Join-Path $script:XAMPP_DIR "apache\modules"
        $lines = Get-Content $conf
        $changed = $false
        $out = foreach ($line in $lines) {
            if ($line -match '^\s*LoadModule\s+\S+\s+modules/(\S+\.so)') {
                $so = $Matches[1]
                if (-not (Test-Path (Join-Path $modDir $so))) {
                    Write-Warn "  нет модуля: $so — закомментирован"
                    "# $line"; $changed = $true; continue
                }
            }
            $line
        }
        if ($changed) { Set-Content $conf -Value ($out -join "`r`n") -Encoding ASCII }
    }

    # Проверка через -t без ErrorActionPreference
    $httpd = Join-Path $script:XAMPP_DIR "apache\bin\httpd.exe"
    $eap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $testOut = (& $httpd -t 2>&1 | Out-String)
    $ErrorActionPreference = $eap
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Apache отверг конфиг:"
        Write-Host $testOut -ForegroundColor Red
        Write-Warn "Откат..."
        robocopy "$bak\bin"     (Join-Path $script:XAMPP_DIR 'apache\bin')     /MIR /NFL /NDL /NJH /NJS | Out-Null
        robocopy "$bak\modules" (Join-Path $script:XAMPP_DIR 'apache\modules') /MIR /NFL /NDL /NJH /NJS | Out-Null
        return $false
    }

    Start-Service $script:APACHE_SERVICE -ErrorAction SilentlyContinue
    Write-Success "Apache обновлён до $Compiler. Бэкап: $bak"
    return $true
}

# ============ APACHE CONFIG UPDATE ============
function Update-ApacheConfig {
    param([string]$Version)
    $conf = Join-Path $script:XAMPP_DIR "apache\conf\extra\httpd-xampp.conf"
    if (-not (Test-Path $conf)) { Write-Warn "Не найден: $conf"; return }

    # Чистим старый блок curl-deps
    $raw = Get-Content $conf -Raw
    $raw = $raw -replace '(?ms)# === PVM curl deps.*?# === /PVM curl deps ===\r?\n', ''
    Set-Content -Path $conf -Value $raw -Encoding ASCII

    $phpDir = Join-Path $script:XAMPP_DIR "php"
    $phpPathFwd = ($phpDir -replace '\\','/')

    $dll = Get-ChildItem $phpDir -Filter "php*apache2_4.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dll) { throw "php*apache2_4.dll не найден в $phpDir" }
    $dllName = [string]$dll.Name

    $tsDll = Get-ChildItem $phpDir -Filter "php*ts.dll" -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -match '^php\d*ts\.dll$' } | Select-Object -First 1
    $tsName = if ($tsDll) { [string]$tsDll.Name } else { $null }

    # php7_module для PHP 7.x, php_module для PHP 8.x
    $moduleName = "php_module"
    if ($dllName -match '^php(\d+)apache2_4\.dll$') {
        $major = [int]$Matches[1]
        if ($major -lt 8) { $moduleName = "php${major}_module" }
    }

    # Собираем curl-зависимости
    $curlDeps = @()
    foreach ($cd in @(
        'libssh2.dll','nghttp2.dll','libsodium.dll',
        'libcrypto-1_1-x64.dll','libssl-1_1-x64.dll',
        'libcrypto-3-x64.dll','libssl-3-x64.dll',
        'brotlicommon.dll','brotlidec.dll'
    )) {
        if (Test-Path (Join-Path $phpDir $cd)) { $curlDeps += $cd }
    }

    if ($script:DRY_RUN) {
        Write-Info "[dry-run] module=$moduleName dll=$dllName ts=$tsName deps=$($curlDeps.Count)"
        return
    }
    Write-Info "Обновление httpd-xampp.conf (module=$moduleName, dll=$dllName)..."

    $lines = @(Get-Content $conf)
    $out = New-Object System.Collections.Generic.List[string]
    $moduleWritten = $false
    $tsWritten = $false

    foreach ($line in $lines) {
        if ($line -match '^\s*LoadFile\s+"[^"]*php\d*ts\.dll"') {
            if ($tsName -and -not $tsWritten) {
                $out.Add("LoadFile `"$phpPathFwd/$tsName`"")
                $tsWritten = $true
            }
            continue
        }
        if ($line -match '^\s*LoadModule\s+php\w*_module\s+"[^"]*"') {
            $out.Add("LoadModule $moduleName `"$phpPathFwd/$dllName`"")
            $moduleWritten = $true
            continue
        }
        if ($line -match '^(\s*</?IfModule\s+)php\w*_module(\s*>)') {
            $out.Add("$($Matches[1])$moduleName$($Matches[2])")
            continue
        }
        $out.Add($line)
    }

    if (-not $moduleWritten) { Write-Warn "LoadModule php*_module не найден." }

    $joined = ($out -join "`r`n")

    # Вставляем блок curl deps перед LoadModule
    if ($curlDeps.Count -gt 0) {
        $block = "# === PVM curl deps ===`r`n"
        foreach ($cd in $curlDeps) { $block += "LoadFile `"$phpPathFwd/$cd`"`r`n" }
        $block += "# === /PVM curl deps ===`r`n"
        $joined = $joined -replace '(LoadModule\s+php\w*_module\s+"[^"]*")', ($block + '$1')
    }

    Set-Content -Path $conf -Value $joined -Encoding ASCII
}

# ============ PHP.INI DEFAULTS ============
function Copy-CurlDependencies {
    param([string]$PhpDir)
    $deps = @(
        'libcurl.dll','libssh2.dll','nghttp2.dll','libsodium.dll',
        'libcrypto-3-x64.dll','libssl-3-x64.dll',
        'libcrypto-1_1-x64.dll','libssl-1_1-x64.dll',
        'brotlicommon.dll','brotlidec.dll'
    )
    $extDir = Join-Path $PhpDir 'ext'
    if (-not (Test-Path $extDir)) { return }
    $copied = 0
    foreach ($d in $deps) {
        $src = Join-Path $PhpDir $d
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $extDir $d) -Force
            $copied++
        }
    }
    if ($copied -gt 0) { Write-Info "  curl deps -> ext\: $copied" }
}

function Set-PhpIniDefaults {
    param([string]$IniPath)
    if (-not (Test-Path $IniPath)) { return }
    $c = Get-Content $IniPath -Raw

    # Убираем deprecated-в-PHP-8 директивы
    $c = $c -replace '(?m)^\s*mbstring\.http_output\s*=.*$',       '; mbstring.http_output removed in PHP 8'
    $c = $c -replace '(?m)^\s*mbstring\.internal_encoding\s*=.*$', '; mbstring.internal_encoding removed in PHP 8'
    $c = $c -replace '(?m)^\s*mbstring\.func_overload\s*=.*$',     '; mbstring.func_overload removed in PHP 8'

    # Лимиты
    $c = $c -replace '(?m)^\s*;?\s*upload_max_filesize\s*=.*$',   'upload_max_filesize = 512M'
    $c = $c -replace '(?m)^\s*;?\s*post_max_size\s*=.*$',         'post_max_size = 512M'
    $c = $c -replace '(?m)^\s*;?\s*memory_limit\s*=.*$',          'memory_limit = 1024M'
    $c = $c -replace '(?m)^\s*;?\s*max_execution_time\s*=.*$',    'max_execution_time = 600'
    $c = $c -replace '(?m)^\s*;?\s*max_input_time\s*=.*$',        'max_input_time = 600'
    $c = $c -replace '(?m)^\s*;?\s*max_input_vars\s*=.*$',        'max_input_vars = 5000'

    # UTF-8
    $c = $c -replace '(?m)^\s*;?\s*default_charset\s*=.*$', 'default_charset = "UTF-8"'

    # Dedup extension=mysqli
    $lines = $c -split "`r?`n"
    $seenMysqli = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*extension=mysqli\s*$') {
            if ($seenMysqli) { $lines[$i] = ';' + $lines[$i] + ' # dup removed' }
            else { $seenMysqli = $true }
        }
    }
    $c = $lines -join "`r`n"

    # Добавить отсутствующие ключи
    foreach ($line in @(
        'upload_max_filesize = 512M','post_max_size = 512M','memory_limit = 1024M',
        'max_execution_time = 600','max_input_time = 600','max_input_vars = 5000',
        'default_charset = "UTF-8"'
    )) {
        $key = ($line -split '\s*=\s*')[0]
        if ($c -notmatch "(?m)^\s*$key\s*=") { $c += "`n$line" }
    }

    Set-Content -Path $IniPath -Value $c -Encoding UTF8
}

function Enable-DefaultExtensions {
    param([string]$IniPath)
    $phpDir = Split-Path $IniPath -Parent
    $extAbs = ((Join-Path $phpDir "ext") -replace '\\','/')
    $c = Get-Content $IniPath -Raw
    $c = $c -replace '(?m)^;?\s*extension_dir\s*=\s*"[^"]*"', "extension_dir=`"$extAbs`""
    foreach ($e in @("curl","fileinfo","gd","mbstring","exif","mysqli","openssl",
                     "pdo_mysql","pdo_sqlite","sqlite3","zip","intl","soap","sockets","xsl","opcache")) {
        $c = $c -replace "(?m)^;extension=$e\b", "extension=$e"
    }
    # PHP 7.4 иногда с php_ префиксом
    $c = $c -replace '(?m)^;extension=php_curl\.dll',    'extension=curl'
    $c = $c -replace '(?m)^;extension=php_openssl\.dll', 'extension=openssl'
    Set-Content -Path $IniPath -Value $c -Encoding UTF8
    Set-PhpIniDefaults -IniPath $IniPath
}

# ============ INSTALL PHP ============
function Install-PhpVersion {
    param([string]$Version)
    Ensure-Dirs
    $existing = @(Get-InstalledVersions | Where-Object { $_.Version -eq $Version })
    if ($existing.Count -gt 0) {
        Write-Warn "PHP $Version уже установлена."
        return (Join-Path $VERSIONS_DIR $Version)
    }
    $remoteList = @(Get-RemoteVersions | Where-Object { [string]$_.Version -eq $Version })
    if ($remoteList.Count -eq 0) { Write-Err "Версия $Version не найдена."; return $null }
    $remote = $remoteList[0]
    $fileName = [string]$remote.FileName
    $remoteUrl = [string]$remote.Url
    $zipPath = Join-Path $CACHE_DIR $fileName

    if (-not (Test-Path $zipPath) -or (Get-Item $zipPath).Length -lt 20MB) {
        Write-Info "Скачивание $fileName..."
        $curlExe = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
        if ($curlExe) {
            & $curlExe -L --fail --show-error --silent -o $zipPath $remoteUrl
            if ($LASTEXITCODE -ne 0) { throw "curl.exe не смог скачать" }
        } else {
            Invoke-WebRequest -Uri $remoteUrl -OutFile $zipPath -UseBasicParsing
        }
    } else {
        Write-Info "Из кэша: $fileName"
    }

    $dest = Join-Path $VERSIONS_DIR $Version
    if ($script:DRY_RUN) { Write-Info "[dry-run] распаковал бы в $dest"; return $dest }
    Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    & tar.exe -xf $zipPath -C $dest
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "tar вернул $LASTEXITCODE, пробую Expand-Archive"
        Expand-Archive -Path $zipPath -DestinationPath $dest -Force
    }

    Copy-CurlDependencies -PhpDir $dest

    $iniSrc = Join-Path $dest "php.ini-development"
    $iniDst = Join-Path $dest "php.ini"
    if ((Test-Path $iniSrc) -and -not (Test-Path $iniDst)) {
        Copy-Item $iniSrc $iniDst
        Enable-DefaultExtensions -IniPath $iniDst
    }
    Write-Success "Установлено: $Version"
    return $dest
}

# ============ PHPMYADMIN ============
function Get-ActivePmaVersion {
    if (-not $script:XAMPP_DIR) { return $null }
    $pmaPath = Join-Path $script:XAMPP_DIR "phpMyAdmin"
    if (-not (Test-Path $pmaPath)) { return $null }
    $t = Get-LinkTarget $pmaPath
    if ($t) { return Split-Path $t -Leaf }
    return "unknown"
}

# ============ BACKUP ============
function New-PvmBackup {
    param([string]$Operation)
    if ($script:NO_BACKUP) { return $null }
    if ($script:DRY_RUN) { return "dry-run" }
    Ensure-Dirs
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $dir = Join-Path $BACKUP_DIR "$ts-$Operation"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $state = [ordered]@{}
    if ($script:XAMPP_DIR) {
        $state["xamppDir"] = $script:XAMPP_DIR
        $conf = Join-Path $script:XAMPP_DIR "apache\conf\extra\httpd-xampp.conf"
        if (Test-Path $conf) { Copy-Item $conf (Join-Path $dir "httpd-xampp.conf") -Force; $state["httpdConfig"] = "httpd-xampp.conf" }
        $phpPath = Join-Path $script:XAMPP_DIR "php"
        if (Test-Path $phpPath) {
            $t = Get-LinkTarget $phpPath
            if ($t) { $state["phpJunction"] = $t; $state["phpVersion"] = Split-Path $t -Leaf }
        }
        $pmaPath = Join-Path $script:XAMPP_DIR "phpMyAdmin"
        if (Test-Path $pmaPath) {
            $t = Get-LinkTarget $pmaPath
            if ($t) { $state["pmaJunction"] = $t; $state["pmaVersion"] = Split-Path $t -Leaf }
            $cfg = Join-Path $pmaPath "config.inc.php"
            if (Test-Path $cfg) {
                New-Item -ItemType Directory -Path (Join-Path $dir "phpmyadmin") -Force | Out-Null
                Copy-Item $cfg (Join-Path $dir "phpmyadmin\config.inc.php") -Force
                $state["pmaConfig"] = "phpmyadmin/config.inc.php"
            }
        }
    }
    @{ timestamp=(Get-Date).ToString("o"); operation=$Operation; state=$state } |
        ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir "metadata.json") -Encoding UTF8
    Write-Success "Бэкап: $dir"
    $all = Get-ChildItem $BACKUP_DIR -Directory | Sort-Object Name -Descending
    if ($all.Count -gt $script:KEEP_BACKUPS) {
        $all | Select-Object -Skip $script:KEEP_BACKUPS | ForEach-Object { Remove-Item $_.FullName -Recurse -Force }
    }
    return $dir
}

function Restore-PvmBackup {
    param([string]$BackupDir)
    $mf = Join-Path $BackupDir "metadata.json"
    if (-not (Test-Path $mf)) { return $false }
    $meta = Get-Content $mf -Raw | ConvertFrom-Json
    Write-Info "Откат: $($meta.timestamp)"
    if ($script:DRY_RUN) { return $true }
    if ($meta.state.httpdConfig) {
        Copy-Item (Join-Path $BackupDir $meta.state.httpdConfig) `
            (Join-Path $script:XAMPP_DIR "apache\conf\extra\httpd-xampp.conf") -Force
    }
    if ($meta.state.phpJunction) {
        Create-Junction (Join-Path $script:XAMPP_DIR "php") $meta.state.phpJunction
    }
    if ($meta.state.pmaJunction) {
        Create-Junction (Join-Path $script:XAMPP_DIR "phpMyAdmin") $meta.state.pmaJunction
    }
    if ($meta.state.pmaConfig) {
        $src = Join-Path $BackupDir $meta.state.pmaConfig
        $dst = Join-Path $script:XAMPP_DIR "phpMyAdmin\config.inc.php"
        if (Test-Path $src) { Copy-Item $src $dst -Force }
    }
    Write-Success "Откат завершён."
    return $true
}

# ============ USE ============
function Initialize-Xampp {
    if (-not $script:XAMPP_DIR) { Write-Err "XAMPP не найден."; return $false }
    $phpPath = Join-Path $script:XAMPP_DIR "php"
    if (-not (Test-Path $phpPath)) { Write-Err "Папка php не найдена."; return $false }
    if (Get-LinkTarget $phpPath) { return $true }
    Write-Info "Миграция текущего PHP..."
    if ($script:DRY_RUN) { return $true }
    Stop-Apache
    $phpExe = Join-Path $phpPath "php.exe"
    if (-not (Test-Path $phpExe)) { Write-Err "php.exe не найден."; return $false }
    $ver = (& $phpExe -r "echo PHP_VERSION;" 2>$null).Trim()
    if (-not $ver) { Write-Err "Не определил версию."; return $false }
    $target = Join-Path $VERSIONS_DIR $ver
    if (-not (Test-Path $target)) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Copy-Item -Path (Join-Path $phpPath "*") -Destination $target -Recurse -Force
    }
    $bak = "$phpPath._pvm_backup"
    if (Test-Path $bak) { Remove-Item $bak -Recurse -Force }
    Rename-Item $phpPath $bak -Force
    try { Create-Junction $phpPath $target }
    catch {
        if (Test-Path $phpPath) { Remove-Item $phpPath -Recurse -Force -ErrorAction SilentlyContinue }
        Rename-Item $bak $phpPath -Force
        return $false
    }
    Remove-Item $bak -Recurse -Force -ErrorAction SilentlyContinue
    Write-Success "XAMPP инициализирован ($ver)."
    return $true
}

function Use-PhpVersion {
    param([string]$Version)
    $installed = @(Get-InstalledVersions | Where-Object { $_.Version -eq $Version })
    if ($installed.Count -eq 0) { Write-Err "PHP $Version не установлена."; return }
    if (-not $script:XAMPP_DIR) { Write-Err "XAMPP не найден."; return }

    if (-not (Confirm-Action "Переключить XAMPP на PHP $Version? Apache перезапустится." -DefaultYes)) { return }

    # Apache compatibility
    if (-not (Test-ApachePhpCompatibility -PhpVersion $Version)) {
        $needCompiler = Get-PhpRequiredCompiler -Version $Version
        if (-not (Install-ApacheForCompiler -Compiler $needCompiler)) {
            Write-Err "Отменено: Apache несовместим."; return
        }
    }

    $backupDir = New-PvmBackup -Operation "use-$Version"

    $phpPath = Join-Path $script:XAMPP_DIR "php"
    if (-not (Get-LinkTarget $phpPath)) {
        if (-not (Initialize-Xampp)) { return }
    }

    try {
        Stop-Apache
        Write-Info "Переключаю PHP на $Version..."
        Create-Junction $phpPath $installed[0].Path
        Update-ApacheConfig -Version $Version
    } catch {
        Write-Err "Ошибка: $_"
        if ($backupDir -and $backupDir -ne "dry-run") { Restore-PvmBackup $backupDir | Out-Null }
        return
    }

    # httpd -t с временным Continue
    $httpdExe = Join-Path $script:XAMPP_DIR "apache\bin\httpd.exe"
    if (-not $script:DRY_RUN -and (Test-Path $httpdExe)) {
        Write-Info "Проверка конфигурации Apache..."
        $eap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $testOut = (& $httpdExe -t 2>&1 | Out-String)
        $ErrorActionPreference = $eap
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Apache отверг конфиг:"
            Write-Host $testOut -ForegroundColor Red
            if ($backupDir -and $backupDir -ne "dry-run") {
                Restore-PvmBackup $backupDir | Out-Null
                Start-Apache | Out-Null
            }
            return
        }
    }

    Write-Info "Запускаю Apache..."
    if (-not (Start-Apache)) {
        Write-Err "Apache не поднялся — откат."
        if ($backupDir -and $backupDir -ne "dry-run") {
            Stop-Apache | Out-Null
            Restore-PvmBackup $backupDir | Out-Null
            Start-Apache | Out-Null
        }
        return
    }
    Write-Success "PHP $Version активен. Бэкап: $backupDir"
}

# ============ COMMANDS ============
function Cmd-Help {
@"
pvm v$($script:PVM_VERSION) - PHP Version Manager for XAMPP

USAGE:
  pvm <command> [args] [flags]

FLAGS:
  -y, --yes            Не спрашивать
  --dry-run            Показать план
  --no-backup          Пропустить бэкап (ОПАСНО)
  --keep-backups=N     Хранить N бэкапов

PHP:
  install <ver>        Скачать и установить
  use <ver>            Переключить (все vhosts)
  list | ls            Установленные
  list-remote [f]      Доступные
  current              Активная версия
  uninstall <ver>      Удалить
  tune [ver|--all]     Применить лимиты/UTF-8 ко всем php.ini

BACKUPS:
  backup create|list|restore <id>|prune

OTHER:
  xampp [path]         Путь к XAMPP
  init                 Мигрировать php в junction
  update-cache         Обновить кэш
  help | -h            Справка
  -l | --list          Алиас list
  -v | --version       Версия
"@ | Write-Host
}

function Cmd-Install {
    param($ver)
    if (-not $ver) { Write-Err "Укажите версию."; return }
    Load-Config
    if (Install-PhpVersion -Version $ver) { Write-Info "Активируйте: pvm use $ver" }
}
function Cmd-Use {
    param($ver)
    if (-not $ver) { Write-Err "Укажите версию."; return }
    Load-Config
    Use-PhpVersion -Version $ver
}
function Cmd-List {
    Load-Config
    $installed = Get-InstalledVersions
    if (-not $installed -or @($installed).Count -eq 0) {
        Write-Info "Нет установленных версий PHP."
        return
    }
    $active = Get-ActiveVersion
    Write-Host ""
    Write-Host "Установленные версии PHP:" -F Cyan
    foreach ($v in $installed | Sort-Object Name) {
        $mark = if ($v.Version -eq $active) { " * " } else { "   " }
        $col  = if ($v.Version -eq $active) { "Green" } else { "White" }
        Write-Host "$mark$($v.Version)" -F $col
    }
    if ($active) { Write-Host "`nАктивная PHP: $active" -F Green }
    $pma = Get-ActivePmaVersion
    if ($pma) { Write-Host "Активная phpMyAdmin: $pma" -F Green }
    Write-Host ""
}
function Cmd-ListRemote {
    param($filter)
    Load-Config
    $remote = Get-RemoteVersions
    $installed = @((Get-InstalledVersions).Version)
    if ($filter) { $remote = $remote | Where-Object { $_.Version -like "$filter*" } }
    Write-Host "`nДоступные версии PHP:" -F Cyan
    foreach ($r in $remote | Sort-Object { [version]$_.Version } -Descending) {
        $mark = if ($installed -contains $r.Version) { " [установлена]" } else { "" }
        Write-Host "  $($r.Version)$mark"
    }
    Write-Host ""
}
function Cmd-Current {
    Load-Config
    $a = Get-ActiveVersion
    if ($a) { Write-Host "PHP:        $a" -F Green } else { Write-Warn "PHP: неизвестно" }
    $p = Get-ActivePmaVersion
    if ($p) { Write-Host "phpMyAdmin: $p" -F Green }
}
function Cmd-Uninstall {
    param($ver)
    if (-not $ver) { Write-Err "Укажите версию."; return }
    Load-Config
    $target = Join-Path $VERSIONS_DIR $ver
    if (-not (Test-Path $target)) { Write-Err "Не установлена."; return }
    if ((Get-ActiveVersion) -eq $ver) { Write-Err "Нельзя удалить активную."; return }
    if (-not (Confirm-Action "Удалить PHP $ver?")) { return }
    if (-not $script:DRY_RUN) { Remove-Item $target -Recurse -Force }
    Write-Success "Удалено: $ver"
}
function Cmd-Xampp {
    param($path)
    Load-Config
    if (-not $path) {
        if ($script:XAMPP_DIR) { Write-Host $script:XAMPP_DIR } else { Write-Warn "Не задан." }
        return
    }
    if (-not (Test-Path (Join-Path $path "apache\bin\httpd.exe"))) { Write-Err "Не XAMPP: $path"; return }
    $script:XAMPP_DIR = (Resolve-Path $path).Path
    $script:APACHE_SERVICE = Find-ApacheService
    Save-Config
    Write-Success "XAMPP: $script:XAMPP_DIR"
}
function Cmd-Init { Load-Config; Initialize-Xampp | Out-Null }
function Cmd-UpdateCache {
    Ensure-Dirs
    Get-RemoteVersions -Force | Out-Null
    Write-Success "Кэш обновлён."
}
function Cmd-Tune {
    param([string]$Version, [switch]$All)
    Load-Config; Ensure-Dirs
    $targets = if ($All -or -not $Version) {
        @(Get-InstalledVersions)
    } else {
        @(Get-InstalledVersions | Where-Object { $_.Version -eq $Version })
    }
    if ($targets.Count -eq 0) { Write-Err "Нет версий."; return }
    foreach ($t in $targets) {
        $ini = Join-Path $t.Path "php.ini"
        if (-not (Test-Path $ini)) {
            $dev = Join-Path $t.Path "php.ini-development"
            if (Test-Path $dev) { Copy-Item $dev $ini }
        }
        if (Test-Path $ini) {
            Set-PhpIniDefaults -IniPath $ini
            Copy-CurlDependencies -PhpDir $t.Path
            Write-Success "$($t.Version): обновлён"
        }
    }
    Write-Info "Перезапустите Apache: Restart-Service $($script:APACHE_SERVICE)"
}
function Cmd-Backup {
    param([string]$sub, [string]$arg)
    Load-Config; Ensure-Dirs
    switch ($sub) {
        "create" { New-PvmBackup -Operation "manual" | Out-Null }
        "list" {
            $all = Get-ChildItem $BACKUP_DIR -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
            if (-not $all) { Write-Info "Нет бэкапов."; return }
            Write-Host "`nБэкапы:" -F Cyan
            foreach ($b in $all) { Write-Host "  $($b.Name)" }
            Write-Host ""
        }
        "restore" {
            if (-not $arg) { Write-Err "Укажите ID."; return }
            $dir = Join-Path $BACKUP_DIR $arg
            if (-not (Test-Path $dir)) {
                $match = Get-ChildItem $BACKUP_DIR -Directory | Where-Object { $_.Name -like "$arg*" } | Select-Object -First 1
                if ($match) { $dir = $match.FullName } else { Write-Err "Не найден: $arg"; return }
            }
            if (-not (Confirm-Action "Восстановить?")) { return }
            Stop-Apache; Restore-PvmBackup $dir | Out-Null; Start-Apache | Out-Null
        }
        "prune" {
            $all = Get-ChildItem $BACKUP_DIR -Directory | Sort-Object Name -Descending
            if ($all.Count -le $script:KEEP_BACKUPS) { Write-Info "Нечего чистить."; return }
            $all | Select-Object -Skip $script:KEEP_BACKUPS | ForEach-Object { Remove-Item $_.FullName -Recurse -Force }
            Write-Success "Готово."
        }
        default { Write-Err "backup: create|list|restore|prune" }
    }
}

# ============ MAIN ============
try {
    Enter-Lock
    try {
        switch ($Command.ToLower()) {
            "install"      { Cmd-Install ($Arguments | Select-Object -First 1) }
            "use"          { Cmd-Use     ($Arguments | Select-Object -First 1) }
            "list"         { Cmd-List }
            "ls"           { Cmd-List }
            "list-remote"  { Cmd-ListRemote ($Arguments | Select-Object -First 1) }
            "ls-remote"    { Cmd-ListRemote ($Arguments | Select-Object -First 1) }
            "current"      { Cmd-Current }
            "uninstall"    { Cmd-Uninstall ($Arguments | Select-Object -First 1) }
            "remove"       { Cmd-Uninstall ($Arguments | Select-Object -First 1) }
            "tune"         { Cmd-Tune ($Arguments | Select-Object -First 1) -All:($Arguments -contains '--all') }
            "backup"       { Cmd-Backup ($Arguments | Select-Object -First 1) ($Arguments | Select-Object -Skip 1 -First 1) }
            "xampp"        { Cmd-Xampp ($Arguments | Select-Object -First 1) }
            "init"         { Cmd-Init }
            "update-cache" { Cmd-UpdateCache }
            "help"         { Cmd-Help }
            "--help"       { Cmd-Help }
            ""             { Cmd-Help }
            default        { Write-Err "Неизвестная команда: $Command"; Write-Host "Смотрите: pvm help" }
        }
    } finally { Exit-Lock }
} catch {
    Write-Err "Ошибка: $_"
    Exit-Lock
    exit 1
}