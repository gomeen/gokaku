#requires -Version 5.1
<#
主线程须在全部生产输入任务结束后，以已提升的 64 位管理员运行：
  powershell.exe -NoProfile -File runtime.ps1 -InputActivityFinished
固定传输目录：C:/Users/iixm/AppData/Local/Temp/GogakuAcceptanceB94/installer-fixture
只需上传 runtime.ps1、packages.json、packages/*。本文件未在 Windows 上执行。
任何异常都停止后续安装、卸载与清理，保留现场。截图不是验收证据。
#>
[CmdletBinding()]
param([switch]$InputActivityFinished)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ExpectedTransfer = 'C:\Users\iixm\AppData\Local\Temp\GogakuAcceptanceB94\installer-fixture'
$Base = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
if (-not $Base.Equals($ExpectedTransfer, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing unexpected transfer directory: $Base; expected $ExpectedTransfer"
}
$RunId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N')
$Evidence = Join-Path $Base ('results\' + $RunId)
# Validate the report destination before the first filesystem write.
$ancestor = $Evidence
while ($ancestor) {
    if (Test-Path -LiteralPath $ancestor) {
        $item = Get-Item -LiteralPath $ancestor -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing report reparse point: $ancestor" }
    }
    $parent = [IO.Path]::GetDirectoryName($ancestor)
    if ($parent -eq $ancestor) { break }
    $ancestor = $parent
}
if (Test-Path -LiteralPath $Evidence) { throw "Refusing existing evidence directory: $Evidence" }
[void][IO.Directory]::CreateDirectory($Evidence)
$LatestResult = Join-Path $Base 'result.json'
$MayWriteLatest = -not (Test-Path -LiteralPath $LatestResult)
$Script:CurrentStep = $null
$Script:Baseline = $null
$Script:DataRoots = @()
$Script:FixtureRoot = $null
$Script:Sentinel = $null
$Script:SentinelHash = $null
$Script:RegisterText = ''
$Script:SeededRun = $null
$Script:InitialRun = $null
$Script:AHarvest = $null
$Script:BHarvest = $null
$Script:UninstallerHash = $null
$Script:MutationStarted = $false
$Script:Views = @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)
$RunSubkey = 'Software\Microsoft\Windows\CurrentVersion\Run'
$FixtureClsid = '{B74D13D2-0952-4B54-B124-671170C7A295}'
$FixtureAppId = '{B74D13D2-0952-4B54-B124-671170C7A294}'
$FixtureChannel = 'Software\Gogaku\acceptance-b94'
$FixtureRunName = 'GogakuAcceptanceB94Agent'
$FixtureUninstall = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $FixtureAppId + '_is1'
$Script:Result = [ordered]@{
    schema = 1; ok = $false; status = 'running'; runId = $RunId
    startedAtUtc = [DateTime]::UtcNow.ToString('o'); finishedAtUtc = $null
    inputActivityFinishedAcknowledged = [bool]$InputActivityFinished
    baselineTiming = 'Caller must finish all input tasks before invocation; this script never generates input or stops production processes.'
    transferDirectory = $Base; manifestSha256 = $null; mutationStarted = $false
    runtimeExecuted = $false; cleanupCompleted = $false; error = $null
    steps = [Collections.Generic.List[object]]::new()
    logs = [Collections.Generic.List[string]]::new()
    limitations = @('Controlled registration DLL only; no CTF/TSF keyboard or default input changes.',
        'Failure variants exercise registration failure before pointer/Run migration, not partial migration or unregister failure.',
        'External sentinel and all reports are retained; failure paths deliberately retain fixture state.')
}

function Relative-Evidence([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($Base + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Evidence path escaped transfer directory: $full"
    }
    return $full.Substring($Base.Length + 1).Replace('\', '/')
}
function Add-Log([string]$Path) {
    $relative = Relative-Evidence $Path
    if (-not $Script:Result.logs.Contains($relative)) { $Script:Result.logs.Add($relative) }
    if ($null -ne $Script:CurrentStep -and -not $Script:CurrentStep.logs.Contains($relative)) {
        $Script:CurrentStep.logs.Add($relative)
    }
}
function Save-Report {
    $Script:Result.mutationStarted = $Script:MutationStarted
    $json = ConvertTo-Json -InputObject $Script:Result -Depth 100
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText((Join-Path $Evidence 'result.json'), $json, $utf8)
    if ($MayWriteLatest) { [IO.File]::WriteAllText($LatestResult, $json, $utf8) }
}
function Save-Evidence([string]$Name, $Value) {
    if ($Name -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Invalid evidence filename' }
    $path = Join-Path $Evidence $Name
    $counter = 1
    while (Test-Path -LiteralPath $path) {
        $path = Join-Path $Evidence ([IO.Path]::GetFileNameWithoutExtension($Name) + '-' + $counter + [IO.Path]::GetExtension($Name))
        $counter++
    }
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $Value -Depth 100), [Text.UTF8Encoding]::new($false))
    Add-Log $path
}
function Begin-Step([string]$Name) {
    $Script:CurrentStep = [ordered]@{
        name = $Name; status = 'running'; startedAtUtc = [DateTime]::UtcNow.ToString('o')
        finishedAtUtc = $null; exitCode = $null; processId = $null
        assertions = [Collections.Generic.List[object]]::new()
        logs = [Collections.Generic.List[string]]::new()
    }
    $Script:Result.steps.Add($Script:CurrentStep)
    Save-Report
}
function Assert-That([string]$Name, [bool]$Condition, $Expected, $Actual) {
    $Script:CurrentStep.assertions.Add([ordered]@{
        name = $Name; passed = $Condition; expected = $Expected; actual = $Actual
    })
    if (-not $Condition) { Save-Report; throw "Assertion failed: $Name" }
}
function Complete-Step {
    $Script:CurrentStep.status = 'passed'
    $Script:CurrentStep.finishedAtUtc = [DateTime]::UtcNow.ToString('o')
    Save-Report
}
function Canonical($Value) { return ConvertTo-Json -InputObject $Value -Depth 100 -Compress }
function Same-Object($Left, $Right) { return (Canonical $Left) -ceq (Canonical $Right) }
function File-Sha([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Safe-Path([string]$Root, [string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':')) { throw "Rooted relative path: $Relative" }
    $full = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $full.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escaped allowed root: $Relative"
    }
    return $full
}
function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing reparse point: $current" }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}
function Read-Value($Key, [string]$Name) {
    if ($null -eq $Key -or $Key.GetValueNames() -notcontains $Name) {
        return [ordered]@{ present = $false; kind = $null; data = $null }
    }
    $kind = $Key.GetValueKind($Name).ToString()
    $data = $Key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($data -is [byte[]]) { $data = [Convert]::ToBase64String($data) }
    return [ordered]@{ present = $true; kind = $kind; data = $data }
}
function Read-KeyTree($Key) {
    if ($null -eq $Key) { return [ordered]@{ present = $false; values = @(); children = @() } }
    $values = [Collections.Generic.List[object]]::new()
    foreach ($name in @($Key.GetValueNames() | Sort-Object)) {
        $values.Add([ordered]@{ name = $name; value = (Read-Value $Key $name) })
    }
    $children = [Collections.Generic.List[object]]::new()
    foreach ($name in @($Key.GetSubKeyNames() | Sort-Object)) {
        $child = $Key.OpenSubKey($name, $false)
        try { $children.Add([ordered]@{ name = $name; key = (Read-KeyTree $child) }) }
        finally { if ($null -ne $child) { $child.Dispose() } }
    }
    return [ordered]@{ present = $true; values = $values.ToArray(); children = $children.ToArray() }
}
function Registry-Tree($Hive, $View, [string]$Path) {
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $View)
    $key = $null
    try { $key = $baseKey.OpenSubKey($Path, $false); return Read-KeyTree $key }
    finally { if ($null -ne $key) { $key.Dispose() }; $baseKey.Dispose() }
}
function Registry-Value($Hive, $View, [string]$Path, [string]$Name) {
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $View)
    $key = $null
    try { $key = $baseKey.OpenSubKey($Path, $false); return Read-Value $key $Name }
    finally { if ($null -ne $key) { $key.Dispose() }; $baseKey.Dispose() }
}
function Loaded-Hives {
    $users = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users, [Microsoft.Win32.RegistryView]::Registry64)
    try { return @($users.GetSubKeyNames() | Sort-Object) } finally { $users.Dispose() }
}
function Run-State([string[]]$Names) {
    $items = [Collections.Generic.List[object]]::new()
    foreach ($view in $Script:Views) {
        foreach ($sid in @(Loaded-Hives)) {
            foreach ($name in $Names) {
                $value = Registry-Value ([Microsoft.Win32.RegistryHive]::Users) $view ($sid + '\' + $RunSubkey) $name
                $items.Add([ordered]@{ view = $view.ToString(); sid = $sid; name = $name; value = $value })
            }
        }
    }
    return $items.ToArray()
}
function File-Tree([string]$Root) {
    Assert-NoReparse $Root
    if (-not (Test-Path -LiteralPath $Root)) { return [ordered]@{ present = $false; directories = @(); files = @() } }
    if (-not (Get-Item -LiteralPath $Root -Force).PSIsContainer) { throw "Expected directory: $Root" }
    $todo = [Collections.Generic.Stack[string]]::new()
    $todo.Push($Root)
    $directories = [Collections.Generic.List[string]]::new()
    $files = [Collections.Generic.List[object]]::new()
    while ($todo.Count -gt 0) {
        $dir = $todo.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force | Sort-Object Name)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing reparse point: $($item.FullName)" }
            $relative = $item.FullName.Substring($Root.TrimEnd('\').Length + 1).Replace('\', '/')
            if ($item.PSIsContainer) { $directories.Add($relative); $todo.Push($item.FullName) }
            else {
                $length = $item.Length; $ticks = $item.LastWriteTimeUtc.Ticks
                $sha = File-Sha $item.FullName
                $after = Get-Item -LiteralPath $item.FullName -Force
                if ($after.Length -ne $length -or $after.LastWriteTimeUtc.Ticks -ne $ticks) { throw "File changed during snapshot: $($item.FullName)" }
                $files.Add([ordered]@{ path = $relative; bytes = $length; sha256 = $sha })
            }
        }
    }
    return [ordered]@{
        present = $true; directories = @($directories.ToArray() | Sort-Object)
        files = @($files.ToArray() | Sort-Object { $_.path })
    }
}
function Production-DataRoots {
    $roots = [Collections.Generic.List[string]]::new()
    $roots.Add('C:\Users\iixm\AppData\Local\Gogaku')
    $profiles = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    $list = $null
    try {
        $list = $profiles.OpenSubKey('Software\Microsoft\Windows NT\CurrentVersion\ProfileList', $false)
        if ($null -eq $list) { throw 'ProfileList unavailable' }
        foreach ($sid in @($list.GetSubKeyNames() | Sort-Object)) {
            $key = $list.OpenSubKey($sid, $false)
            try {
                $profile = [Environment]::ExpandEnvironmentVariables([string]$key.GetValue('ProfileImagePath', ''))
                if ($profile) { $roots.Add([IO.Path]::GetFullPath((Join-Path $profile 'AppData\Local\Gogaku'))) }
            } finally { if ($null -ne $key) { $key.Dispose() } }
        }
    } finally { if ($null -ne $list) { $list.Dispose() }; $profiles.Dispose() }
    return @($roots.ToArray() | Sort-Object -Unique)
}
function Production-State {
    $registry = [Collections.Generic.List[object]]::new()
    $clsids = @('{A3C5D7E9-1B2F-4A6C-8E0D-2F4B6A8C0E12}', '{A3C5D7E9-1B2F-4A6C-8E0D-2F4B6A8C0E13}')
    $appids = @('{0F3E6E4A-6D7B-4C1E-9B2A-5C8D7E1F3A21}', '{7B2D9C4E-1A3F-4E6B-8C5D-2F7A9B1C3E42}')
    foreach ($view in $Script:Views) {
        $paths = [Collections.Generic.List[string]]::new()
        foreach ($clsid in $clsids) {
            $paths.Add('Software\Classes\CLSID\' + $clsid)
            $paths.Add('Software\Microsoft\CTF\TIP\' + $clsid)
        }
        foreach ($channel in @('stable', 'dev')) { $paths.Add('Software\Gogaku\' + $channel) }
        foreach ($appid in $appids) { $paths.Add('Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $appid + '_is1') }
        foreach ($path in $paths) {
            $registry.Add([ordered]@{ hive = 'HKLM'; view = $view.ToString(); path = $path
                tree = (Registry-Tree ([Microsoft.Win32.RegistryHive]::LocalMachine) $view $path) })
        }
        foreach ($sid in @(Loaded-Hives)) {
            foreach ($clsid in $clsids) {
                $path = $sid + '\Software\Classes\CLSID\' + $clsid
                $registry.Add([ordered]@{ hive = 'HKU'; view = $view.ToString(); path = $path
                    tree = (Registry-Tree ([Microsoft.Win32.RegistryHive]::Users) $view $path) })
            }
            foreach ($suffix in @('Keyboard Layout\Preload', 'Keyboard Layout\Substitutes')) {
                $path = $sid + '\' + $suffix
                $registry.Add([ordered]@{ hive = 'HKU'; view = $view.ToString(); path = $path
                    tree = (Registry-Tree ([Microsoft.Win32.RegistryHive]::Users) $view $path) })
            }
        }
    }
    $data = [Collections.Generic.List[object]]::new()
    $roots = @(Production-DataRoots)
    foreach ($root in $roots) { $data.Add([ordered]@{ root = $root; tree = (File-Tree $root) }) }
    return [ordered]@{
        registry = $registry.ToArray(); run = @(Run-State @('GogakuAgent', 'GogakuDevAgent'))
        dataRoots = $roots; data = $data.ToArray()
    }
}
function Check-Production([string]$Tag) {
    $state = Production-State
    Save-Evidence ($Tag + '-production.json') $state
    foreach ($part in @('registry', 'run', 'dataRoots', 'data')) {
        $same = Same-Object $Script:Baseline[$part] $state[$part]
        Assert-That ('production.' + $part + '.unchanged') $same 'exact baseline equality' $same
    }
}
function Fixture-State {
    $com = [Collections.Generic.List[object]]::new()
    $uninstall = [Collections.Generic.List[object]]::new()
    foreach ($view in $Script:Views) {
        $path = 'Software\Classes\CLSID\' + $FixtureClsid
        $com.Add([ordered]@{ view = $view.ToString()
            key = (Registry-Tree ([Microsoft.Win32.RegistryHive]::LocalMachine) $view $path)
            inproc = (Registry-Value ([Microsoft.Win32.RegistryHive]::LocalMachine) $view ($path + '\InprocServer32') '')
            threadingModel = (Registry-Value ([Microsoft.Win32.RegistryHive]::LocalMachine) $view ($path + '\InprocServer32') 'ThreadingModel') })
        $uninstall.Add([ordered]@{ view = $view.ToString()
            key = (Registry-Tree ([Microsoft.Win32.RegistryHive]::LocalMachine) $view $FixtureUninstall) })
    }
    return [ordered]@{
        com = $com.ToArray(); uninstall = $uninstall.ToArray()
        active = (Registry-Value ([Microsoft.Win32.RegistryHive]::LocalMachine) ([Microsoft.Win32.RegistryView]::Registry64) $FixtureChannel 'ActiveRoot')
        previous = (Registry-Value ([Microsoft.Win32.RegistryHive]::LocalMachine) ([Microsoft.Win32.RegistryView]::Registry64) $FixtureChannel 'PreviousRoot')
        run = @(Run-State @($FixtureRunName))
        files = $(if ($Script:FixtureRoot) { File-Tree $Script:FixtureRoot } else { $null })
    }
}
function Check-Fixture([string]$Active, [string]$Previous, [string]$Tag) {
    $state = Fixture-State
    Save-Evidence ($Tag + '-fixture.json') $state
    foreach ($com in $state.com) {
        $arch = if ($com.view -eq 'Registry64') { 'x64' } else { 'x86' }
        $dll = Join-Path $Active ('bin\' + $arch + '\GogakuTsf.dll')
        Assert-That ($arch + '.COM') ($com.inproc.present -and $com.inproc.kind -eq 'String' -and $com.inproc.data -ieq $dll) $dll $com.inproc
        Assert-That ($arch + '.threadingModel') ($com.threadingModel.present -and $com.threadingModel.data -ceq 'Apartment') 'Apartment' $com.threadingModel
    }
    Assert-That 'ActiveRoot' ($state.active.present -and $state.active.kind -eq 'String' -and $state.active.data -ieq $Active) $Active $state.active
    Assert-That 'PreviousRoot' ($state.previous.present -and $state.previous.kind -eq 'String' -and $state.previous.data -ieq $Previous) $Previous $state.previous
    $uninstall64 = @($state.uninstall | Where-Object { $_.view -eq 'Registry64' })[0]
    Assert-That 'fixture.uninstallRecord.present' $uninstall64.key.present $true $uninstall64.key.present
    $uninstaller = Join-Path $Script:FixtureRoot 'unins000.exe'
    Assert-That 'fixture.uninstaller.present' ([IO.File]::Exists($uninstaller)) $true ([IO.File]::Exists($uninstaller))
}
function Check-Sentinel {
    Assert-NoReparse $Script:Sentinel
    $exists = [IO.File]::Exists($Script:Sentinel)
    $hash = if ($exists) { File-Sha $Script:Sentinel } else { $null }
    Assert-That 'externalDataSentinel.retained' ($exists -and $hash -ceq $Script:SentinelHash) $Script:SentinelHash $hash
}
function Check-Payload([string]$Name, [string]$Root) {
    $entry = $Manifest.packages.PSObject.Properties[$Name].Value
    $identityPath = Join-Path $Root 'build-identity.json'
    Assert-NoReparse $identityPath
    $hash = File-Sha $identityPath
    Assert-That ($Name + '.identity.sha256') ($hash -ceq $entry.identitySha256) $entry.identitySha256 $hash
    $identity = Get-Content -LiteralPath $identityPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-That ($Name + '.identity.fields') ($identity.fixture -eq $true -and $identity.fullVersion -eq '1.0.0' -and $identity.buildNumber -eq $entry.build -and $identity.channel -eq 'acceptance-b94' -and $identity.variant -eq $Name) $Name $identity.variant
    $tree = File-Tree $Root
    $expectedNames = [Collections.Generic.List[string]]::new()
    $expectedNames.Add('build-identity.json')
    foreach ($property in @($identity.artifacts.PSObject.Properties | Sort-Object Name)) {
        $relative = $property.Name.Replace('\', '/')
        $file = Safe-Path $Root $relative
        Assert-NoReparse $file
        $expectedNames.Add($relative)
        $expected = $property.Value
        $actual = File-Sha $file
        $length = (Get-Item -LiteralPath $file -Force).Length
        Assert-That ($Name + '.file.' + $relative) ($actual -ceq $expected.sha256 -and $length -eq $expected.bytes) $expected ([ordered]@{ sha256 = $actual; bytes = $length })
    }
    $actualNames = @($tree.files | ForEach-Object { $_.path } | Sort-Object)
    $wantedNames = @($expectedNames.ToArray() | Sort-Object)
    Assert-That ($Name + '.fileSet.exact') (Same-Object $wantedNames $actualNames) $wantedNames $actualNames
    Save-Evidence ($Script:CurrentStep.name + '-' + $Name + '-payload.json') $tree
    return $tree
}
function Copy-RegistrationLog([string]$Tag) {
    $path = Join-Path $Script:FixtureRoot 'fixture-register.log'
    if ([IO.File]::Exists($path)) {
        Assert-NoReparse $path
        $dest = Join-Path $Evidence ($Tag + '-register.log')
        [IO.File]::Copy($path, $dest, $false)
        Add-Log $dest
        return [IO.File]::ReadAllText($dest, [Text.Encoding]::UTF8)
    }
    return ''
}
function Check-Events([string]$Tag, [string]$InnoLog, [string[]]$Expected) {
    $text = Copy-RegistrationLog $Tag
    Assert-That 'registerLog.appendOnly' ($text.StartsWith($Script:RegisterText, [StringComparison]::Ordinal)) 'unchanged earlier log prefix' $text.Length
    $new = $text.Substring($Script:RegisterText.Length)
    $lines = @($new -split '\r?\n' | Where-Object { $_.Length -gt 0 })
    Assert-That 'registerLog.eventCount' ($lines.Count -eq $Expected.Count) $Expected.Count $lines.Count
    $events = [Collections.Generic.List[object]]::new()
    $pattern = '^(?<time>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z)\tpid=(?<pid>\d+)\tarch=(?<arch>x64|x86)\top=(?<op>register|unregister)\thr=(?<hr>0x[0-9a-fA-F]{8})\tinjected=(?<injected>[01])\tmodule=(?<module>.+)$'
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        $match = [regex]::Match($lines[$i], $pattern)
        Assert-That ('registerLog.format.' + $i) $match.Success $pattern $lines[$i]
        $parts = $Expected[$i].Split('|')
        $root = if ($parts[2] -eq 'A') { $ARoot } else { $BRoot }
        $module = Join-Path $root ('bin\' + $parts[0] + '\GogakuTsf.dll')
        $actual = [ordered]@{
            arch = $match.Groups['arch'].Value; operation = $match.Groups['op'].Value
            hr = $match.Groups['hr'].Value.ToLowerInvariant(); injected = $match.Groups['injected'].Value
            module = $match.Groups['module'].Value; processId = [long]$match.Groups['pid'].Value
            time = $match.Groups['time'].Value
        }
        $ok = $actual.arch -ceq $parts[0] -and $actual.operation -ceq $parts[1] -and $actual.hr -ceq $parts[3] -and $actual.injected -ceq $parts[4] -and $actual.module -ieq $module -and $actual.processId -gt 0
        Assert-That ('registerLog.event.' + $i) $ok $Expected[$i] $actual
        $events.Add($actual)
    }
    $detail = [IO.File]::ReadAllText($InnoLog)
    $calls = [regex]::Matches($detail, '(?m)^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\s+(?<arch>x64|x86) regsvr32 (?<module>[^\r\n]+?) exit=(?<exit>-?\d+)\r?$')
    Assert-That 'inno.regsvrCallCount' ($calls.Count -eq $events.Count) $events.Count $calls.Count
    for ($i = 0; $i -lt $events.Count; $i++) {
        $exitCode = [int]$calls[$i].Groups['exit'].Value
        $event = $events[$i]
        $codeOk = if ($event.hr -ceq '0x80004005') { $exitCode -gt 0 } else { $exitCode -eq 0 }
        $ok = $codeOk -and $calls[$i].Groups['arch'].Value -ceq $event.arch -and $calls[$i].Groups['module'].Value -ieq $event.module
        Assert-That ('inno.regsvrCall.' + $i) $ok $event ([ordered]@{ exitCode = $exitCode; module = $calls[$i].Groups['module'].Value; arch = $calls[$i].Groups['arch'].Value })
    }
    Save-Evidence ($Tag + '-events.json') $events.ToArray()
    $Script:RegisterText = $text
}
function Check-Package([string]$Name) {
    $entry = $Manifest.packages.PSObject.Properties[$Name].Value
    $relative = 'packages/' + $Name + '.exe'
    Assert-That ($Name + '.relativePath') ($entry.relativePath -ceq $relative) $relative $entry.relativePath
    $path = Safe-Path $Base $relative
    Assert-NoReparse $path
    $hash = File-Sha $path
    $length = (Get-Item -LiteralPath $path -Force).Length
    Assert-That ($Name + '.package.sha256') ($hash -ceq $entry.sha256 -and $length -eq $entry.bytes) $entry.sha256 $hash
    return $path
}
function Invoke-Installer([string]$Name, [string[]]$Events, [bool]$Failure) {
    Begin-Step $Name
    Check-Production ($Name + '-before')
    if ($Name -ne 'A') {
        Check-Fixture $ARoot '' ($Name + '-before')
        Check-RunAgainst $Script:SeededRun 'fixture.Run.matchesBeforeUpgrade'
        $aBefore = Check-Payload 'A' $ARoot
        Assert-That 'A.preservedBeforeUpgrade' (Same-Object $Script:AHarvest $aBefore) 'original A file set/SHA' $aBefore
        $bBefore = File-Tree $BRoot
        Assert-That 'B.noFilesBeforeUpgrade' (@($bBefore.files).Count -eq 0) @() $bBefore.files
    }
    $package = Check-Package $Name
    $log = Join-Path $Evidence ($Name + '-inno.log')
    $arguments = @('/SP-', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/TASKS=""', ('/LOG="' + $log + '"'))
    $Script:CurrentStep['command'] = [ordered]@{ file = $package; arguments = $arguments }
    $Script:CurrentStep['launchAttempted'] = $true
    $Script:MutationStarted = $true
    Save-Report
    $process = Start-Process -FilePath $package -ArgumentList $arguments -Wait -PassThru
    $process.WaitForExit()
    $exitCode = $process.ExitCode
    $Script:CurrentStep.processId = $process.Id
    $Script:CurrentStep.exitCode = $exitCode
    $Script:Result.runtimeExecuted = $true
    if ([IO.File]::Exists($log)) { Add-Log $log }
    [void](Copy-RegistrationLog ($Name + '-raw'))
    Assert-That 'process.exitCode.available' ($null -ne $exitCode) 'real process ExitCode' $exitCode
    $exitOk = if ($Failure) { $exitCode -ne 0 } else { $exitCode -eq 0 }
    Assert-That 'process.exitCode' $exitOk $(if ($Failure) { 'nonzero' } else { 0 }) $exitCode
    Assert-That 'inno.log.present' ([IO.File]::Exists($log)) $true ([IO.File]::Exists($log))
    Check-Events $Name $log $Events
    Check-Sentinel
    Check-Production ($Name + '-after')
}
function Check-RunAgainst($Expected, [string]$Label) {
    $actual = @(Run-State @($FixtureRunName))
    Assert-That $Label (Same-Object $Expected $actual) $Expected $actual
}
function Check-FailureRollback([string]$Name) {
    Check-Fixture $ARoot '' $Name
    Check-RunAgainst $Script:SeededRun 'fixture.Run.preservedAfterFailure'
    $a = Check-Payload 'A' $ARoot
    Assert-That 'A.fileSetAndSHA.preserved' (Same-Object $Script:AHarvest $a) 'original A payload file set/SHA' $a
    $b = File-Tree $BRoot
    Assert-That 'B.allFiles.rolledBack' (@($b.files).Count -eq 0) @() $b.files
    Save-Evidence ($Name + '-rolled-back-B.json') $b
    Complete-Step
}
function Seed-Run {
    $before = @(Run-State @($FixtureRunName))
    Assert-That 'fixture.Run.absentBeforeSeed' (@($before | Where-Object { $_.value.present }).Count -eq 0) 'absent in all loaded hives/views' $before
    $users = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users, [Microsoft.Win32.RegistryView]::Registry64)
    $key = $null
    try {
        # Do not create or load hives or change a shared Run container.
        $key = $users.OpenSubKey($RunUserSid + '\' + $RunSubkey, $true)
        if ($null -eq $key) { throw 'Target user Run container absent; refusing to create an unrelated container' }
        if ($key.GetValueNames() -contains $FixtureRunName) { throw 'Isolated Run value appeared before seed; refusing overwrite' }
        $key.SetValue($FixtureRunName, ('"' + (Join-Path $ARoot 'bin\x64\GogakuAgent.exe') + '"'), [Microsoft.Win32.RegistryValueKind]::String)
    } finally { if ($null -ne $key) { $key.Dispose() }; $users.Dispose() }
    $Script:SeededRun = @(Run-State @($FixtureRunName))
    $present = @($Script:SeededRun | Where-Object { $_.value.present })
    $wanted = '"' + (Join-Path $ARoot 'bin\x64\GogakuAgent.exe') + '"'
    Assert-That 'fixture.Run.seededSingleUser' ($present.Count -gt 0 -and @($present | Where-Object { $_.sid -cne $RunUserSid -or $_.value.data -cne $wanted -or $_.value.kind -ne 'String' }).Count -eq 0) $RunUserSid $present
    Save-Evidence 'seeded-fixture-run.json' $Script:SeededRun
}
function Cleanup-OwnResidual {
    Begin-Step 'cleanup'
    Check-Production 'cleanup-before'
    $state = Fixture-State
    $unknown = @($state.files.files | Where-Object { $_.path -cne 'fixture-register.log' })
    Assert-That 'cleanup.noUnknownFiles' ($unknown.Count -eq 0) @() $unknown
    $knownDirectories = [Collections.Generic.List[string]]::new()
    $knownDirectories.Add('versions')
    foreach ($record in @(
        [ordered]@{ prefix = 'versions/1.0.0-b1-acceptance-b94'; tree = $Script:AHarvest },
        [ordered]@{ prefix = 'versions/1.0.0-b2-acceptance-b94'; tree = $Script:BHarvest }
    )) {
        $knownDirectories.Add($record.prefix)
        foreach ($relative in $record.tree.directories) { $knownDirectories.Add($record.prefix + '/' + $relative) }
    }
    $unknownDirectories = @($state.files.directories | Where-Object { $knownDirectories -notcontains $_ })
    Assert-That 'cleanup.noUnknownDirectories' ($unknownDirectories.Count -eq 0) @() $unknownDirectories
    foreach ($com in $state.com) { Assert-That ('cleanup.COM.absent.' + $com.view) (-not $com.key.present) $false $com.key.present }
    Assert-That 'cleanup.noRun' (@($state.run | Where-Object { $_.value.present }).Count -eq 0) 'absent' $state.run
    Assert-That 'cleanup.noPointers' (-not $state.active.present -and -not $state.previous.present) 'absent' @($state.active, $state.previous)
    foreach ($record in $state.uninstall) { Assert-That ('cleanup.uninstall.absent.' + $record.view) (-not $record.key.present) $false $record.key.present }
    # Validate the entire cleanup plan before deleting even our archived log.
    foreach ($view in $Script:Views) {
        $tree = Registry-Tree ([Microsoft.Win32.RegistryHive]::LocalMachine) $view $FixtureChannel
        $empty = -not $tree.present -or (@($tree['values']).Count -eq 0 -and @($tree['children']).Count -eq 0)
        Assert-That ('cleanup.channelPlanEmpty.' + $view) $empty 'absent or empty isolated channel key' $tree
    }
    Check-Sentinel
    $liveLog = Join-Path $Script:FixtureRoot 'fixture-register.log'
    $savedLog = Join-Path $Evidence 'uninstall-register.log'
    if ([IO.File]::Exists($liveLog)) {
        Assert-That 'cleanup.logArchived' ((File-Sha $liveLog) -ceq (File-Sha $savedLog)) (File-Sha $savedLog) (File-Sha $liveLog)
        [IO.File]::Delete($liveLog)
    }
    # No recursive deletion. All paths come from the already checked isolated root.
    foreach ($relative in @($state.files.directories | Sort-Object Length -Descending)) {
        $path = Safe-Path $Script:FixtureRoot $relative
        Assert-NoReparse $path
        [IO.Directory]::Delete($path, $false)
    }
    if ([IO.Directory]::Exists($Script:FixtureRoot)) { [IO.Directory]::Delete($Script:FixtureRoot, $false) }
    foreach ($view in $Script:Views) {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        $key = $null
        try {
            $key = $baseKey.OpenSubKey($FixtureChannel, $false)
            if ($null -ne $key) {
                $empty = $key.GetValueNames().Count -eq 0 -and $key.GetSubKeyNames().Count -eq 0
                Assert-That ('cleanup.channelEmpty.' + $view) $empty 'no unknown values or subkeys' $empty
                $key.Dispose(); $key = $null
                $baseKey.DeleteSubKey($FixtureChannel, $false)
            }
        } finally { if ($null -ne $key) { $key.Dispose() }; $baseKey.Dispose() }
    }
    Check-Sentinel
    Assert-That 'cleanup.installRootAbsent' (-not (Test-Path -LiteralPath $Script:FixtureRoot)) $false (Test-Path -LiteralPath $Script:FixtureRoot)
    Check-Production 'final'
    $Script:Result.cleanupCompleted = $true
    Complete-Step
}

try {
    Begin-Step 'preflight'
    Assert-That 'caller.inputFinished' ([bool]$InputActivityFinished) '-InputActivityFinished after all production input tasks ended' ([bool]$InputActivityFinished)
    Assert-That 'previousResult.absent' $MayWriteLatest 'no prior result.json; preserve previous run evidence' (-not $MayWriteLatest)
    Assert-That 'OS.Windows64Process' ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and [Environment]::Is64BitOperatingSystem -and [Environment]::Is64BitProcess) '64-bit PowerShell on Windows x64' ([Environment]::OSVersion.ToString())
    $version = [Environment]::OSVersion.Version
    Assert-That 'OS.Windows11' ($version.Major -ge 10 -and ($version.Major -gt 10 -or $version.Build -ge 22000)) 'Windows 11 build >=22000' $version.ToString()
    $operator = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($operator)
    Assert-That 'operator.alreadyElevated' ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'already elevated; never prompt UAC or runas' $operator.Name
    $OperatorSid = $operator.User.Value
    $Script:Result['operator'] = [ordered]@{ name = $operator.Name; sid = $OperatorSid }
    # SSH elevation may use a different account. Seed only the loaded iixm hive.
    $targetProfile = 'C:\Users\iixm'
    $candidates = [Collections.Generic.List[string]]::new()
    $profileBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    $profileList = $null
    try {
        $profileList = $profileBase.OpenSubKey('Software\Microsoft\Windows NT\CurrentVersion\ProfileList', $false)
        if ($null -eq $profileList) { throw 'ProfileList unavailable' }
        foreach ($sid in @($profileList.GetSubKeyNames())) {
            $profileKey = $profileList.OpenSubKey($sid, $false)
            try {
                $image = [Environment]::ExpandEnvironmentVariables([string]$profileKey.GetValue('ProfileImagePath', ''))
                if ($image -and [IO.Path]::GetFullPath($image).TrimEnd('\') -ieq $targetProfile) { $candidates.Add($sid) }
            } finally { if ($null -ne $profileKey) { $profileKey.Dispose() } }
        }
    } finally { if ($null -ne $profileList) { $profileList.Dispose() }; $profileBase.Dispose() }
    Assert-That 'fixture.Run.targetUserUnique' ($candidates.Count -eq 1) $targetProfile $candidates.ToArray()
    $RunUserSid = $candidates[0]
    Assert-That 'fixture.Run.targetUserLoaded' (@(Loaded-Hives) -contains $RunUserSid) 'target hive already loaded; never load offline hives' $RunUserSid
    $Script:Result['fixtureRunUser'] = [ordered]@{ profile = $targetProfile; sid = $RunUserSid }
    Assert-NoReparse $Base
    $manifestPath = Join-Path $Base 'packages.json'
    Assert-NoReparse $manifestPath
    $Manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $Script:Result.manifestSha256 = File-Sha $manifestPath
    Assert-That 'manifest.schemaAndFixture' ($Manifest.schema -eq 1 -and $Manifest.fixtureOnly -eq $true) 'schema 1, fixtureOnly true' $Manifest.schema
    $wantedIdentity = [ordered]@{
        appId = $FixtureAppId; channel = 'acceptance-b94'; tsfClsid = $FixtureClsid
        runValue = $FixtureRunName; mutex = 'GogakuAcceptanceB94Settings'
        defaultDirName = '{autopf}\GogakuAcceptanceB94'
        channelKey64 = 'HKLM\' + $FixtureChannel
        clsidKeyBothViews = 'HKLM\Software\Classes\CLSID\' + $FixtureClsid
        uninstallKey64 = 'HKLM\' + $FixtureUninstall
    }
    foreach ($name in $wantedIdentity.Keys) {
        $property = $Manifest.identity.PSObject.Properties[$name]
        $actual = if ($null -ne $property) { $property.Value } else { $null }
        Assert-That ('manifest.identity.' + $name) ($actual -ceq $wantedIdentity[$name]) $wantedIdentity[$name] $actual
    }
    Assert-That 'ProgramW6432.available' (-not [string]::IsNullOrWhiteSpace($env:ProgramW6432)) 'ProgramW6432' $env:ProgramW6432
    $Script:FixtureRoot = [IO.Path]::GetFullPath((Join-Path $env:ProgramW6432 'GogakuAcceptanceB94')).TrimEnd('\')
    $ARoot = Join-Path $Script:FixtureRoot 'versions\1.0.0-b1-acceptance-b94'
    $BRoot = Join-Path $Script:FixtureRoot 'versions\1.0.0-b2-acceptance-b94'
    $Script:Result['fixtureRoot'] = $Script:FixtureRoot
    $order = @('A', 'B-fail-x64', 'B-fail-x86', 'B-success')
    $packageNames = @($Manifest.packages.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
    Assert-That 'manifest.packageSet' (Same-Object $packageNames @($order | Sort-Object)) $order $packageNames
    foreach ($name in $order) {
        $entry = $Manifest.packages.PSObject.Properties[$name].Value
        $expectedRoot = if ($name -eq 'A') { $ARoot } else { $BRoot }
        $expectedBuild = if ($name -eq 'A') { 1 } else { 2 }
        $resolved = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($entry.expectedVersionRoot))
        Assert-That ($name + '.versionAndRoot') ($entry.version -eq '1.0.0' -and $entry.build -eq $expectedBuild -and $entry.channel -eq 'acceptance-b94' -and $resolved -ieq $expectedRoot) $expectedRoot $resolved
        [void](Check-Package $name)
    }
    Assert-NoReparse $Script:FixtureRoot
    Assert-That 'fixture.installRoot.absent' (-not (Test-Path -LiteralPath $Script:FixtureRoot)) 'absent' (Test-Path -LiteralPath $Script:FixtureRoot)
    foreach ($view in $Script:Views) {
        foreach ($path in @(('Software\Classes\CLSID\' + $FixtureClsid), $FixtureChannel, $FixtureUninstall)) {
            $tree = Registry-Tree ([Microsoft.Win32.RegistryHive]::LocalMachine) $view $path
            Assert-That ('fixture.registry.absent.' + $view + '.' + $path) (-not $tree.present) 'absent' $tree
        }
        foreach ($sid in @(Loaded-Hives)) {
            foreach ($suffix in @(('Software\Classes\CLSID\' + $FixtureClsid), 'Software\Gogaku\acceptance-b94', $FixtureUninstall)) {
                $tree = Registry-Tree ([Microsoft.Win32.RegistryHive]::Users) $view ($sid + '\' + $suffix)
                Assert-That ('fixture.userIdentity.absent.' + $view + '.' + $sid + '.' + $suffix) (-not $tree.present) 'absent' $tree
            }
        }
    }
    $Script:InitialRun = @(Run-State @($FixtureRunName))
    Assert-That 'fixture.Run.absentAllLoadedHives' (@($Script:InitialRun | Where-Object { $_.value.present }).Count -eq 0) 'absent in both views of every loaded hive' $Script:InitialRun
    $runContainer = Registry-Tree ([Microsoft.Win32.RegistryHive]::Users) ([Microsoft.Win32.RegistryView]::Registry64) ($RunUserSid + '\' + $RunSubkey)
    Assert-That 'targetUser.RunContainer.exists' $runContainer.present 'existing iixm Run container' $RunUserSid
    foreach ($mutexName in @('GogakuAcceptanceB94Settings', 'Global\GogakuAcceptanceB94Settings')) {
        $exists = $false; $mutex = $null
        try { $mutex = [Threading.Mutex]::OpenExisting($mutexName); $exists = $true }
        catch [Threading.WaitHandleCannotBeOpenedException] { $exists = $false }
        finally { if ($null -ne $mutex) { $mutex.Dispose() } }
        Assert-That ('fixture.mutex.absent.' + $mutexName) (-not $exists) 'absent' $exists
    }
    $sentinelDir = Join-Path $env:ProgramData 'GogakuAcceptanceB94'
    Assert-NoReparse $sentinelDir
    Assert-That 'fixture.externalDataRoot.absent' (-not (Test-Path -LiteralPath $sentinelDir)) 'absent; never reuse unknown sentinel' (Test-Path -LiteralPath $sentinelDir)
    $Script:Sentinel = Join-Path $sentinelDir 'external-data-sentinel.txt'
    $Script:Baseline = Production-State
    Save-Evidence 'baseline-production.json' $Script:Baseline
    Check-Production 'baseline-stability'
    # The caller controls quiescence. Never kill agents, suspend processes or change preferences to obtain a stable baseline.
    $Script:MutationStarted = $true
    [void][IO.Directory]::CreateDirectory($sentinelDir)
    $stream = [IO.File]::Open($Script:Sentinel, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes('GogakuAcceptanceB94 external data sentinel ' + $RunId)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
    $Script:SentinelHash = File-Sha $Script:Sentinel
    $Script:Result['externalSentinel'] = [ordered]@{ path = $Script:Sentinel; sha256 = $Script:SentinelHash; retained = $false }
    Check-Sentinel
    Complete-Step

    Invoke-Installer 'A' @('x64|register|A|0x00000000|0', 'x86|register|A|0x00000000|0') $false
    Check-Fixture $ARoot '' 'A'
    Check-RunAgainst $Script:InitialRun 'fixture.Run.initiallyAbsent'
    $Script:AHarvest = Check-Payload 'A' $ARoot
    Assert-That 'B.absentAfterA' (-not (Test-Path -LiteralPath $BRoot)) 'absent' (Test-Path -LiteralPath $BRoot)
    Seed-Run
    Check-Production 'A-after-seed'
    Complete-Step

    Invoke-Installer 'B-fail-x64' @(
        'x64|register|B|0x80004005|1', 'x86|unregister|B|0x00000000|0', 'x64|unregister|B|0x00000000|0',
        'x64|register|A|0x00000000|0', 'x86|register|A|0x00000000|0') $true
    Check-FailureRollback 'B-fail-x64'

    Invoke-Installer 'B-fail-x86' @(
        'x64|register|B|0x00000000|0', 'x86|register|B|0x80004005|1',
        'x86|unregister|B|0x00000000|0', 'x64|unregister|B|0x00000000|0',
        'x64|register|A|0x00000000|0', 'x86|register|A|0x00000000|0') $true
    Check-FailureRollback 'B-fail-x86'

    Invoke-Installer 'B-success' @('x64|register|B|0x00000000|0', 'x86|register|B|0x00000000|0') $false
    Check-Fixture $BRoot $ARoot 'B-success'
    $Script:BHarvest = Check-Payload 'B-success' $BRoot
    $aAfter = Check-Payload 'A' $ARoot
    Assert-That 'A.preservedAfterSuccess' (Same-Object $Script:AHarvest $aAfter) 'original A file set/SHA' $aAfter
    $expectedRun = ConvertFrom-Json (ConvertTo-Json -InputObject $Script:SeededRun -Depth 100)
    foreach ($item in $expectedRun) {
        if ($item.value.present) { $item.value.data = '"' + (Join-Path $BRoot 'bin\x64\GogakuAgent.exe') + '"' }
    }
    Check-RunAgainst @($expectedRun) 'fixture.Run.migratedSingleUser'
    $Script:UninstallerHash = File-Sha (Join-Path $Script:FixtureRoot 'unins000.exe')
    Complete-Step

    Begin-Step 'uninstall'
    Check-Production 'uninstall-before'
    Check-Fixture $BRoot $ARoot 'uninstall-before'
    $bBefore = Check-Payload 'B-success' $BRoot
    Assert-That 'B.preservedBeforeUninstall' (Same-Object $Script:BHarvest $bBefore) 'original B file set/SHA' $bBefore
    Check-RunAgainst @($expectedRun) 'fixture.Run.matchesBeforeUninstall'
    $uninstaller = Join-Path $Script:FixtureRoot 'unins000.exe'
    Assert-NoReparse $uninstaller
    $currentHash = File-Sha $uninstaller
    Assert-That 'uninstaller.sha256.pinned' ($currentHash -ceq $Script:UninstallerHash) $Script:UninstallerHash $currentHash
    $innoLog = Join-Path $Evidence 'uninstall-inno.log'
    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ('/LOG="' + $innoLog + '"'))
    $Script:CurrentStep['command'] = [ordered]@{ file = $uninstaller; arguments = $arguments }
    $Script:CurrentStep['launchAttempted'] = $true
    Save-Report
    $process = Start-Process -FilePath $uninstaller -ArgumentList $arguments -Wait -PassThru
    $process.WaitForExit()
    $exitCode = $process.ExitCode
    $Script:CurrentStep.processId = $process.Id; $Script:CurrentStep.exitCode = $exitCode
    if ([IO.File]::Exists($innoLog)) { Add-Log $innoLog }
    [void](Copy-RegistrationLog 'uninstall-raw')
    Assert-That 'uninstall.exitCode.available' ($null -ne $exitCode) 'real process ExitCode' $exitCode
    Assert-That 'uninstall.exitCode.zero' ($exitCode -eq 0) 0 $exitCode
    Check-Events 'uninstall' $innoLog @('x64|unregister|B|0x00000000|0', 'x86|unregister|B|0x00000000|0')
    $after = Fixture-State
    Save-Evidence 'uninstall-fixture.json' $after
    foreach ($com in $after.com) { Assert-That ('uninstall.COM.absent.' + $com.view) (-not $com.key.present) 'absent' $com.key }
    foreach ($record in $after.uninstall) { Assert-That ('uninstall.record.absent.' + $record.view) (-not $record.key.present) 'absent' $record.key }
    Assert-That 'uninstall.ActiveRoot.absent' (-not $after.active.present) 'absent' $after.active
    Assert-That 'uninstall.PreviousRoot.absent' (-not $after.previous.present) 'absent' $after.previous
    Assert-That 'uninstall.Run.absentAllLoadedHives' (@($after.run | Where-Object { $_.value.present }).Count -eq 0) 'absent' $after.run
    foreach ($root in @($ARoot, $BRoot)) {
        $tree = File-Tree $root
        Assert-That ('uninstall.payloadFilesAbsent.' + $root) (@($tree.files).Count -eq 0) @() $tree.files
    }
    Assert-That 'uninstall.uninstallerAbsent' (-not [IO.File]::Exists($uninstaller)) 'absent' ([IO.File]::Exists($uninstaller))
    Check-Sentinel
    Check-Production 'uninstall-after'
    Complete-Step
    Cleanup-OwnResidual
    $Script:Result.externalSentinel.retained = $true
    $Script:Result.ok = $true
    $Script:Result.status = 'passed'
}
catch {
    $failure = $_
    $Script:Result.status = 'failed'
    $Script:Result.error = [ordered]@{
        message = $failure.Exception.Message; exception = $failure.Exception.ToString()
        position = $failure.InvocationInfo.PositionMessage; scriptStackTrace = $failure.ScriptStackTrace
    }
    if ($null -ne $Script:CurrentStep) {
        $Script:CurrentStep.status = 'failed'
        $Script:CurrentStep.finishedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    # Read-only diagnostics only. Never uninstall, restore registry, delete Run values or clean unknown state here.
    try {
        if ($Script:FixtureRoot) {
            [void](Copy-RegistrationLog 'failure')
            Save-Evidence 'failure-fixture.json' (Fixture-State)
        }
    } catch { $Script:Result['fixtureDiagnosticError'] = $_.Exception.ToString() }
    try {
        if ($null -ne $Script:Baseline) {
            $finalState = Production-State
            Save-Evidence 'failure-production.json' $finalState
            $Script:Result['productionUnchangedAtFailure'] = Same-Object $Script:Baseline $finalState
        }
    } catch { $Script:Result['productionDiagnosticError'] = $_.Exception.ToString() }
    if ($Script:Sentinel -and [IO.File]::Exists($Script:Sentinel)) {
        try { $Script:Result['sentinelSha256AtFailure'] = File-Sha $Script:Sentinel }
        catch { $Script:Result['sentinelDiagnosticError'] = $_.Exception.ToString() }
    }
}
finally {
    $Script:Result.finishedAtUtc = [DateTime]::UtcNow.ToString('o')
    Save-Report
}
Write-Output (Join-Path $Evidence 'result.json')
if (-not $Script:Result.ok) { exit 1 }
exit 0
