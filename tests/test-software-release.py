#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, os, subprocess, sys, tempfile

root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='dfr-release-test-') as td_raw:
    td=Path(td_raw)
    helper=td/'registry.py'
    subprocess.run([str(root/'tests'/'extract-registry.py'),str(helper)],check=True,stdout=subprocess.DEVNULL,timeout=10)
    env=os.environ.copy()
    env.update(
        DFR_STATE_ROOT=str(td/'state'),
        DFR_REGISTRY_DB=str(td/'state/database/registry.sqlite3'),
        DFR_BACKUP_DIR=str(td/'state/backups'),
        DFR_CONFIG_ROOT=str(td/'etc'),
        DFR_REGISTRY_RUNTIME_STATE=str(td/'runtime.json'),
        DFR_NFT='/bin/true',
        DFR_TC='/bin/true',
    )
    def run(*args,check=True):
        return subprocess.run([sys.executable,str(helper),*map(str,args)],env=env,check=check,text=True,capture_output=True,timeout=10)

    run('init','--endpoint','198.51.100.44')
    key=td/'release.key'; pub=td/'release.pub'; sig=td/'release.sig'; manifest_file=td/'release.json'
    key.write_text('-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VwBCIEIPe0Rtj3wXPspQY70+cjBb7lC0XLhvB8uZeK6kYtcimq\n-----END PRIVATE KEY-----\n'); pub.write_text('-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAV5yxuSpxDz/+w43jyd+yTraoFOfM5riKluBodmuqbG8=\n-----END PUBLIC KEY-----\n')

    version='v2.1.1-test1'
    payload=td/'dragon-fruit-relay-ingress.sh'
    payload.write_text('#!/usr/bin/env bash\nset -Eeuo pipefail\nreadonly APP_VERSION="'+version+'"\nexit 0\n')
    os.chmod(payload,0o755)
    subprocess.run(['bash','-n',str(payload)],check=True,timeout=10)
    digest=hashlib.sha256(payload.read_bytes()).hexdigest()
    manifest={
        'format':'dragon-fruit-relay-ingress-release',
        'format_version':1,
        'version':version,
        'sha256':digest,
        'role':'ingress',
        'minimum_control_protocol':1,
        'config_schema':1,
        'enrollment_token_version':1,
        'apply_mode':'safe-rollback',
        'reconcile_required':True,
        'capabilities':['release-sha-report-v1','server-endpoint-sync-v2'],
        'created_at':1,
    }
    canonical=json.dumps(manifest,sort_keys=True,separators=(',',':'))
    manifest_file.write_text(canonical)
    subprocess.run(['openssl','pkeyutl','-sign','-rawin','-inkey',str(key),'-in',str(manifest_file),'-out',str(sig)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
    subprocess.run(['openssl','pkeyutl','-verify','-pubin','-inkey',str(pub),'-rawin','-in',str(manifest_file),'-sigfile',str(sig)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)

    run('release-publish',version,'--payload',payload,'--signature',sig,'--sha256',digest,'--manifest-json',canonical,'--status','staged')
    info=json.loads(run('release-info',version).stdout); assert info['status']=='staged' and info['sha256']==digest
    run('release-status',version,'canary'); assert json.loads(run('release-info',version).stdout)['status']=='canary'
    run('release-status',version,'stable'); assert json.loads(run('release-info',version).stdout)['status']=='stable'
    run('release-status',version,'revoked'); assert json.loads(run('release-info',version).stdout)['status']=='revoked'
    blocked=run('release-status',version,'canary',check=False)
    assert blocked.returncode != 0 and 'cannot be reactivated' in (blocked.stderr+blocked.stdout)
    run('release-delete',version)
    missing=run('release-info',version,check=False); assert missing.returncode != 0 and 'unknown release' in (missing.stderr+missing.stdout)

    bad=dict(manifest); bad['version']='v2.1.1-test2'; bad['enrollment_token_version']=2
    bad_canonical=json.dumps(bad,sort_keys=True,separators=(',',':'))
    rejected=run('release-publish',bad['version'],'--payload',payload,'--signature',sig,'--sha256',digest,'--manifest-json',bad_canonical,'--status','staged',check=False)
    assert rejected.returncode != 0 and 'enrollment-token contract mismatch' in (rejected.stderr+rejected.stdout)

print('software release contract: Ed25519 signing, DFR1 manifest, STAGED/CANARY/STABLE/REVOKED lifecycle OK')
