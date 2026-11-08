$ErrorActionPreference='Stop'
try {
 $root=(Get-Item 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Gogaku\dev').GetValue('ActiveRoot')
 $identity=Get-Content -Raw (Join-Path $root 'build-identity.json')|ConvertFrom-Json
 $agentManifest=($identity.artifacts.PSObject.Properties|Where-Object{$_.Name -eq 'bin/x64/GogakuAgent.exe'}).Value.sha256
 function Stop-OwnAgents {
  $ids=@()
  foreach($candidate in @(Get-CimInstance Win32_Process|Where-Object{$_.Name -eq 'GogakuAgent.exe'})){
   if($candidate.ExecutablePath -notlike 'C:\Program Files\GogakuDev\*'){throw ('unexpected agent outside install roots: '+$candidate.ExecutablePath)}
   $old=Get-Process -Id $candidate.ProcessId -ErrorAction SilentlyContinue
   if($old){Stop-Process -Id $candidate.ProcessId -Force;if(-not $old.WaitForExit(3000)){throw 'own agent did not exit'}}
   $ids+=$candidate.ProcessId
  }
  return $ids
 }
 $attempts=@();$ok=$false
 for($try=1;$try -le 8 -and -not $ok;$try++){
  $stopped=Stop-OwnAgents
  $p=Start-Process -FilePath "$root\bin\x64\GogakuAgent.exe" -PassThru
  Start-Sleep -Milliseconds 600
  $agents=@(Get-CimInstance Win32_Process|Where-Object{$_.Name -eq 'GogakuAgent.exe'}|ForEach-Object{
   [pscustomobject]@{pid=$_.ProcessId;path=$_.ExecutablePath;sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $_.ExecutablePath).Hash.ToLower()}})
  $correct=($agents.Count -eq 1 -and $agents[0].path -eq "$root\bin\x64\GogakuAgent.exe" -and $agents[0].sha256 -eq $agentManifest)
  $pipe=@(Get-ChildItem '\\.\pipe\' -ErrorAction SilentlyContinue|Where-Object{$_.Name -like 'Gogaku*-dev'}).Count -ge 1
  $attempts+=@{try=$try;stopped=$stopped;launched=$p.Id;agents=$agents;correct=$correct;pipePresent=$pipe}
  $ok=$correct -and $pipe
 }
 $stable=$false
 if($ok){
  Start-Sleep -Milliseconds 2000
  $agents=@(Get-CimInstance Win32_Process|Where-Object{$_.Name -eq 'GogakuAgent.exe'}|ForEach-Object{
   [pscustomobject]@{pid=$_.ProcessId;path=$_.ExecutablePath;sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $_.ExecutablePath).Hash.ToLower()}})
  $stable=($agents.Count -eq 1 -and $agents[0].path -eq "$root\bin\x64\GogakuAgent.exe")
 }
 $oldHosts=@()
 foreach($proc in @(Get-CimInstance Win32_Process|Where-Object{$_.Name -match '^(chrome|notepad|msedge|Code|Cursor|WindowsTerminal|explorer|SearchHost|StartMenuExperienceHost|ShellExperienceHost|ctfmon|RuntimeBroker|Widgets)\.exe$'})){
  try {
   $m=Get-Process -Id $proc.ProcessId -ErrorAction Stop
   if($m.Modules){
    $hit=@($m.Modules|Where-Object{$_.ModuleName -eq 'GogakuTsf.dll'}|Select-Object -First 1)
    if($hit){$oldHosts+=[pscustomobject]@{pid=$proc.ProcessId;name=$proc.Name;dll=$hit.FileName}}
   }
  } catch {}
 }
 @{ok=($ok -and $stable);attempts=$attempts;stable=$stable;activeRoot=$root;oldTsfHosts=$oldHosts}|ConvertTo-Json -Depth 8|Set-Content -Encoding UTF8 (Join-Path $PSScriptRoot 'result.json')
} catch {@{ok=$false;error=($_|Out-String)}|ConvertTo-Json -Depth 3|Set-Content -Encoding UTF8 (Join-Path $PSScriptRoot 'result.json')}
