#!/usr/bin/env python3
from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
source=(root/'main-engine'/'dragon-fruit-relay-egress.sh').read_text()
start="cat > \"$REGISTRY_HELPER\" <<'PY_DFR_REGISTRY'\n"
if start not in source:
    raise SystemExit('registry helper start marker not found')
body=source.split(start,1)[1].split('\nPY_DFR_REGISTRY\n',1)[0]+'\n'
out=Path(sys.argv[1]) if len(sys.argv)>1 else root/'tests'/'registry-helper.extracted.py'
out.write_text(body)
out.chmod(0o700)
print(out)
