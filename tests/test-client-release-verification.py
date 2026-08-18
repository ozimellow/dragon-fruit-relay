#!/usr/bin/env python3
from pathlib import Path
import base64, hashlib, json, os, subprocess, tempfile

root=Path(__file__).resolve().parents[1]
text=(root/'main-engine'/'dragon-fruit-relay-ingress.sh').read_text()
start="cat > \"$CONTROL_AGENT\" <<'PY_DFR_CONTROL_AGENT'\n"
assert start in text
agent=text.split(start,1)[1].split('\nPY_DFR_CONTROL_AGENT\n',1)[0]
ns={'__name__':'dfr_release_verification_test'}
exec(compile(agent,'<dfr-control-agent>','exec'),ns)
verify_release=ns['verify_release']
compact=ns['compact']

with tempfile.TemporaryDirectory(prefix='dfr-client-release-') as td_raw:
    td=Path(td_raw); updates=td/'updates'; key=td/'release.key'; pub=td/'release.pub'
    key.write_text('-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VwBCIEIPe0Rtj3wXPspQY70+cjBb7lC0XLhvB8uZeK6kYtcimq\n-----END PRIVATE KEY-----\n'); pub.write_text('-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAV5yxuSpxDz/+w43jyd+yTraoFOfM5riKluBodmuqbG8=\n-----END PUBLIC KEY-----\n')
    ns['UPDATE_DIR']=updates; ns['PUBLIC_KEY']=pub
    version='v2.1.1-test1'
    payload=('#!/usr/bin/env bash\nset -Eeuo pipefail\nreadonly APP_VERSION="'+version+'"\nexit 0\n').encode()
    digest=hashlib.sha256(payload).hexdigest()
    manifest={
        'format':'dragon-fruit-relay-ingress-release','format_version':1,'version':version,'sha256':digest,
        'role':'ingress','minimum_control_protocol':1,'config_schema':1,'enrollment_token_version':1,
        'apply_mode':'safe-rollback','reconcile_required':True,
        'capabilities':['release-sha-report-v1','server-endpoint-sync-v2'],'created_at':1,
    }
    manifest_path=td/'release.json'; manifest_path.write_text(compact(manifest))
    sig=td/'release.sig'
    subprocess.run(['openssl','pkeyutl','-sign','-rawin','-inkey',str(key),'-in',str(manifest_path),'-out',str(sig)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
    release={'version':version,'sha256':digest,'manifest':manifest,'payload_b64':base64.b64encode(payload).decode(),'signature_b64':base64.b64encode(sig.read_bytes()).decode()}
    staged=verify_release(release)
    assert staged.read_bytes()==payload and os.access(staged,os.X_OK)

    bad=dict(release); bad['payload_b64']=base64.b64encode(payload+b'\n# tampered\n').decode()
    try: verify_release(bad)
    except RuntimeError as exc: assert 'checksum mismatch' in str(exc)
    else: raise AssertionError('tampered payload was accepted')

    bad=dict(release); damaged=bytearray(sig.read_bytes()); damaged[-1]^=1; bad['signature_b64']=base64.b64encode(bytes(damaged)).decode()
    try: verify_release(bad)
    except RuntimeError as exc: assert 'signature verification failed' in str(exc)
    else: raise AssertionError('tampered signature was accepted')

    bad_manifest=dict(manifest); bad_manifest['config_schema']=2
    bad=dict(release); bad['manifest']=bad_manifest
    try: verify_release(bad)
    except RuntimeError as exc: assert 'configuration schema mismatch' in str(exc)
    else: raise AssertionError('unsupported Client configuration schema was accepted')

print('Client release verification: checksum, Ed25519 signature, shell syntax, version and schema gates OK')
