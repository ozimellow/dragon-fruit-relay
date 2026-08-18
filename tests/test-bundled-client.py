#!/usr/bin/env python3
from pathlib import Path
import re,binascii,gzip,hashlib
root=Path(__file__).resolve().parents[1]
e=(root/'main-engine'/'dragon-fruit-relay-egress.sh').read_text(); ingress=(root/'main-engine'/'dragon-fruit-relay-ingress.sh').read_bytes()
sha=re.search(r'readonly BUNDLED_INGRESS_SHA256="([0-9a-f]{64})"',e).group(1)
block=e.split("cat <<'DFR_BUNDLED_INGRESS_HEX'",1)[1].split('\nDFR_BUNDLED_INGRESS_HEX\n',1)[0]
# Drop shell pipeline text before the first newline, then decode the hex body.
hextext=''.join(block.split('\n',1)[1].split())
embedded=gzip.decompress(binascii.unhexlify(hextext))
assert embedded==ingress
assert hashlib.sha256(embedded).hexdigest()==sha
assert b'readonly APP_VERSION="v2.1.0"' in embedded
print('bundled Client: byte-for-byte match and SHA-256 OK')
