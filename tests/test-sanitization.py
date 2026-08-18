#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
# Construct audit needles so the retired names are not themselves stored in release text.
needles=[
 ''.join(['D','F','R','M','I']), ''.join(['V','I','P']), ''.join(['v','i','p']), ''.join(['r','e','v','e','r','s','e']),
 ''.join(['r','o','u','t','e','-','p','o','o','l']), ''.join(['d','n','s','-','p','o','o','l'])
]
allowed={root/'tests'/'test-sanitization.py'}
hits=[]
for p in root.rglob('*'):
    if not p.is_file() or p in allowed or p.name in {'MANIFEST.sha256'}: continue
    try: text=p.read_text(errors='strict')
    except (UnicodeDecodeError,OSError): continue
    low=text.lower()
    for n in needles:
        if n.lower() in low: hits.append((str(p.relative_to(root)),n)); break
if hits:
    raise SystemExit('sanitization audit failed: '+repr(hits[:30]))
print('sanitization audit: no retired product-line identifiers in current release text')
