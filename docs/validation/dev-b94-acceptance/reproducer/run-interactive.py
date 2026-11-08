#!/usr/bin/env python3
"""Run a local PowerShell diagnostic in the logged-in Windows VM session.

Uses an existing SSH key, an interactive scheduled task, and a temporary directory.
The script being run must write result.json; screenshots remain in that directory.
"""
import argparse
import base64
import json
from pathlib import Path
import subprocess
import time


def remote(host, script, timeout=25):
    script = "[Console]::OutputEncoding=[Text.Encoding]::UTF8; $ProgressPreference='SilentlyContinue'; " + script
    encoded = base64.b64encode(script.encode('utf-16le')).decode('ascii')
    return subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=6', host,
                           'powershell.exe -NoProfile -NonInteractive -EncodedCommand ' + encoded],
                          capture_output=True, text=True, errors='replace', timeout=timeout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('script', type=Path)
    parser.add_argument('--host', default='Administrator@172.16.14.129')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    task = 'GogakuProbe-' + str(int(time.time()))
    desktop = remote(args.host, """$u=(Get-CimInstance Win32_ComputerSystem).UserName
$sid=([System.Security.Principal.NTAccount]$u).Translate([System.Security.Principal.SecurityIdentifier]).Value
$p=Get-CimInstance Win32_UserProfile | Where-Object {$_.SID -eq $sid}
@{user=$u;profile=$p.LocalPath}|ConvertTo-Json -Compress""")
    desktop = json.loads(desktop.stdout)
    if not desktop['user'] or not desktop['profile']:
        raise RuntimeError('No logged-in desktop user')
    guest = desktop['profile'].replace('\\', '/') + '/AppData/Local/Temp/' + task
    init = remote(args.host, "New-Item -ItemType Directory -Force -Path '" + guest + "' | Out-Null")
    if init.returncode:
        raise RuntimeError(init.stderr)
    subprocess.run(['scp', '-q', str(args.script), args.host + ':' + guest + '/probe.ps1'], check=True)
    command = f'''$ErrorActionPreference='Stop'
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{guest}/probe.ps1"'
$principal=New-ScheduledTaskPrincipal -UserId '{desktop['user']}' -LogonType Interactive -RunLevel Limited
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName '{task}' -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName '{task}'
'''
    started = remote(args.host, command)
    if started.returncode:
        raise RuntimeError(started.stderr)
    try:
        # Bounded command execution, not an unattended long test runner.
        for _ in range(24):
            result = remote(args.host, f"if(Test-Path '{guest}/result.json'){{Get-Content -Raw -Encoding UTF8 '{guest}/result.json'}}", timeout=12)
            if result.stdout.strip():
                data = json.loads(result.stdout.lstrip('\ufeff'))
                (args.output / 'result.json').write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
                print(json.dumps(data, ensure_ascii=False, indent=2))
                for filename in data.get('screenshots', []):
                    subprocess.run(['scp', '-q', args.host + ':' + guest + '/' + filename,
                                    str(args.output / filename)], check=True)
                break
            time.sleep(0.5)
        else:
            status = remote(args.host, f"Get-ScheduledTaskInfo -TaskName '{task}' | ConvertTo-Json")
            raise RuntimeError('No result.json from guest task: ' + status.stdout + status.stderr)
    finally:
        cleanup = remote(args.host, f"Unregister-ScheduledTask -TaskName '{task}' -Confirm:$false")
        if cleanup.returncode:
            print(cleanup.stderr)


if __name__ == '__main__':
    main()
