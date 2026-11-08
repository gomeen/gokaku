from pathlib import Path
import importlib.util,json
root=Path.cwd();s=importlib.util.spec_from_file_location('r',root/'.build/windows-diagnosis/run-interactive.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
r=m.remote('Administrator@172.16.14.129',r'''$ErrorActionPreference='Continue'
$removed=@()
$backup='C:\Users\iixm\AppData\Local\Temp\GogakuFixB96\task-definitions'
New-Item -ItemType Directory -Force -Path $backup|Out-Null
foreach($task in @(Get-ScheduledTask -TaskName 'GogakuProbe-*' -ErrorAction SilentlyContinue)){
 $owned=@($task.Actions|Where-Object{$_.Arguments -match ('[/\\]'+[regex]::Escape($task.TaskName)+'[/\\]probe\.ps1')}).Count -eq 1
 if($task.TaskName -eq 'GogakuProbe-1793953155' -and @($task.Actions|Where-Object{$_.Execute -like '*/GogakuProbe-1793953155/host-probe-b94.exe' -and $_.Arguments -eq 'window-state'}).Count -eq 1){$owned=$true}
 if($task.State -eq 'Ready' -and $owned){Export-ScheduledTask -TaskName $task.TaskName|Set-Content -Encoding Unicode (Join-Path $backup ($task.TaskName+'.xml'));Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false;$removed+=$task.TaskName}
}
foreach($name in @('GogakuInstallDevB95','GogakuInstallDevB96','GogakuInstallDevB97','GogakuInstallDevB98')){Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue}
$root98=(Get-Item 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Gogaku\dev').GetValue('ActiveRoot')
$clsid='{A3C5D7E9-1B2F-4A6C-8E0D-2F4B6A8C0E13}'
$com64=(Get-Item "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\CLSID\$clsid\InprocServer32").GetValue('')
$com32=(Get-Item "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\WOW6432Node\CLSID\$clsid\InprocServer32").GetValue('')
$security=Get-MpComputerStatus
@{ok=($com64 -eq "$root98\bin\x64\GogakuTsf.dll" -and $com32 -eq "$root98\bin\x86\GogakuTsf.dll");activeRoot=$root98;com64=$com64;com32=$com32;staleProbeTasksRemoved=$removed;remainingProbeTasks=@(Get-ScheduledTask -TaskName 'GogakuProbe-*' -ErrorAction SilentlyContinue|Select TaskName,State);remainingInstallTasks=@(Get-ScheduledTask -TaskName 'GogakuInstallDev*' -ErrorAction SilentlyContinue|Select TaskName,State);security=@{AMServiceEnabled=$security.AMServiceEnabled;AntivirusEnabled=$security.AntivirusEnabled;RealTimeProtectionEnabled=$security.RealTimeProtectionEnabled};agents=@(Get-CimInstance Win32_Process|Where-Object{$_.Name -eq 'GogakuAgent.exe'}|Select ProcessId,SessionId,ExecutablePath)}|ConvertTo-Json -Depth 7
''');r.check_returncode();value=json.loads(r.stdout.lstrip('\ufeff'));(root/'local/windows-tsf-diagnosis/cleanup98.json').write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n');print(json.dumps(value,ensure_ascii=False,indent=2));assert value['ok'] and not value['remainingProbeTasks'] and not value['remainingInstallTasks'] and value['security']['RealTimeProtectionEnabled']
