#!/usr/bin/env python3
from pathlib import Path
import re, shutil

root=Path(__file__).resolve().parents[1]
p=root/'main-engine'/'dragon-fruit-relay-ingress.sh'
text=p.read_text()

# Exclude generated heredoc payloads; they are syntax-checked separately.
lines=text.splitlines(); kept=[]; marker=None
for line in lines:
    if marker is not None:
        if line.strip()==marker:
            marker=None
        continue
    kept.append(line)
    m=re.search(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?",line)
    if m:
        marker=m.group(1)
text='\n'.join(kept)

defs=set(re.findall(r'(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{',text))
prefixes=(
    'activate_','backup_','check_','cleanup_','cloudflare_','configured_',
    'confirm_','delete_','detect_','diagnostics_','dragonfruit_','ensure_',
    'finalize_','find_','hub_','ingress_','install_','load_','managed_',
    'parse_','pause_','prepare_','print_','prompt_','record_','remove_',
    'repair_','resolve_','restore_','run_','safe_','show_','start_','stop_',
    'subscription_','ui_','validate_','verify_','write_'
)

unknown=[]
for lineno,line in enumerate(text.splitlines(),1):
    if not line.strip() or line.lstrip().startswith('#'):
        continue
    # A helper call can begin a shell command segment after normal separators.
    for segment in re.split(r'(?:&&|\|\||;|\{|\})',line):
        s=segment.strip()
        if not s:
            continue
        changed=True
        while changed:
            old=s
            s=re.sub(r'^(?:if|then|elif|else|while|until|do)\s+','',s)
            s=re.sub(r'^!\s*','',s)
            # Peel simple leading environment/variable assignments.
            m=re.match(r'^[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|\'[^\']*\'|\$\([^)]*\)|\$\{[^}]*\}|[^\s;]+)\s+',s)
            if m:
                s=s[m.end():]
            changed=(s!=old)
        m=re.match(r'^([a-z_][a-z0-9_]*)\b',s)
        if not m:
            continue
        name=m.group(1)
        boundary=m.group(0)[-1] if len(m.group(0))>len(name) else ''
        after=s[len(name):len(name)+1]
        if after in '[=:+-%':
            continue
        if not name.startswith(prefixes):
            continue
        # case labels such as _managed-foo) are not command invocations.
        first=s.split(None,1)[0]
        if ')' in first:
            continue
        if name in defs or shutil.which(name):
            continue
        unknown.append((lineno,name,s[:120]))

if unknown:
    for lineno,name,segment in unknown:
        print(f'{p}:{lineno}: unresolved internal helper {name}: {segment}')
    raise SystemExit(1)

# Regression for the exact fresh-install failure found on Debian 13.
for retired_missing_helper in ('ensure_state_dirs','backup_package_state'):
    assert re.search(rf'\b{retired_missing_helper}\b',text) is None, retired_missing_helper

print(f'Client internal-call audit: {len(defs)} functions, no unresolved helper commands')
