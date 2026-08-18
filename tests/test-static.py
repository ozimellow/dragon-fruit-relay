#!/usr/bin/env python3
from pathlib import Path
import re, subprocess, tempfile, sys
root=Path(__file__).resolve().parents[1]
files=[root/'install.sh',root/'main-engine'/'dragon-fruit-relay-egress.sh',root/'main-engine'/'dragon-fruit-relay-ingress.sh']
for f in files:
    text=f.read_text()
    if not text.startswith('#!/usr/bin/env bash'):
        raise SystemExit(f'{f}: release entrypoint is not the expected Bash engine')
for f in files[1:]:
    if 'dfr_ui_header ()' not in f.read_text() or f.stat().st_size < 200000:
        raise SystemExit(f'{f}: release engine surface is unexpectedly truncated/replaced')
for f in files:
    subprocess.run(['bash','-n',str(f)],check=True)

# Dead-code guard on real shell source only (generated heredocs are audited below).
def shell_surface(path):
    kept=[]; marker=None
    for line in path.read_text().splitlines():
        if marker is not None:
            if line.strip()==marker:
                marker=None
            continue
        kept.append(line)
        m=re.search(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?",line)
        if m:
            marker=m.group(1)
    return '\n'.join(kept)

for f in files[1:]:
    surface=shell_surface(f)
    defs=re.findall(r'(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{',surface)
    duplicate=sorted({name for name in defs if defs.count(name)>1})
    if duplicate:
        raise SystemExit(f'{f}: duplicate function definitions: {duplicate}')
    definition_only=[name for name in defs if len(re.findall(rf'\b{re.escape(name)}\b',surface))==1]
    if definition_only:
        raise SystemExit(f'{f}: definition-only functions: {definition_only}')

checked_bash=checked_python=0
for f in files[1:]:
    lines=f.read_text().splitlines(); i=0
    while i < len(lines):
        m=re.search(r"<<'([A-Z][A-Z0-9_]+)'", lines[i])
        if not m: i+=1; continue
        marker=m.group(1); j=i+1
        while j < len(lines) and lines[j].strip()!=marker: j+=1
        if j>=len(lines): raise SystemExit(f'{f}:{i+1}: unterminated heredoc {marker}')
        body='\n'.join(lines[i+1:j])+'\n'
        first=next((x.strip() for x in body.splitlines() if x.strip()),'')
        if first in ('#!/usr/bin/env python3','#!/usr/bin/python3') or first.startswith('import ') or first.startswith('from '):
            compile(body,f'{f}:{i+1}:{marker}','exec'); checked_python+=1
        elif first in ('#!/usr/bin/env bash','#!/bin/bash'):
            with tempfile.NamedTemporaryFile('w',delete=False) as t: t.write(body); name=t.name
            subprocess.run(['bash','-n',name],check=True); Path(name).unlink(missing_ok=True); checked_bash+=1
        i=j+1
print(f'static syntax: engines=2 generated_bash={checked_bash} embedded_python={checked_python}')
