import subprocess,sys,json
from pathlib import Path
mode=sys.argv[1]
allowed={'notepad-cold','notepad-basic','notepad-raw-enter','notepad-escape','notepad-zero','notepad-number','notepad-shift','notepad-replace','terminal-basic','chrome-basic','chrome-password','chrome-focus','code-basic'}
if mode not in allowed:raise SystemExit('unknown acceptance mode')
script=Path('local/windows-acceptance/run-case.ps1')
script.write_text(r'''$ErrorActionPreference='Stop'
$base='C:\Users\iixm\AppData\Local\Temp\GogakuAcceptanceB94'
Remove-Item (Join-Path $base 'result.json') -ErrorAction SilentlyContinue
$p=Start-Process -FilePath (Join-Path $base 'host-acceptance.exe') -ArgumentList '@MODE@' -PassThru -Wait
Copy-Item (Join-Path $base 'result.json') (Join-Path $PSScriptRoot 'result.json')
$r=Get-Content -Raw -Encoding UTF8 (Join-Path $base 'result.json')|ConvertFrom-Json
foreach($image in $r.screenshots){Copy-Item (Join-Path $base $image) (Join-Path $PSScriptRoot $image)}
'''.replace('@MODE@',mode))
output=Path('local/windows-acceptance')/(sys.argv[2] if len(sys.argv)>2 else mode)
p=subprocess.run([sys.executable,str(Path(__file__).with_name('run-interactive.py')),str(script),'--output',str(output)],capture_output=True,text=True)
if (output/'result.json').exists():
 r=json.loads((output/'result.json').read_text());print(json.dumps(r,ensure_ascii=False,indent=2));raise SystemExit(0 if r['ok'] else 1)
print(p.stdout,p.stderr);raise SystemExit(p.returncode or 2)
