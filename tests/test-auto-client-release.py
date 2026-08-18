#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,os,sqlite3,subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
e=(root/'main-engine'/'dragon-fruit-relay-egress.sh').read_text()
assert "update_policy TEXT NOT NULL DEFAULT 'auto'" in e
assert 'maintain_auto_updates(c)' in e
assert 'ensure_bundled_ingress_stable_release' in e
assert 'registry_command init --endpoint "$SERVER_ENDPOINT" && ensure_bundled_ingress_stable_release' in e
assert "ensure_registry_current; ensure_bundled_ingress_stable_release; repair_all_clients" in e

with tempfile.TemporaryDirectory(prefix='dfr-auto-release-') as td_raw:
    td=Path(td_raw); helper=td/'registry.py'
    subprocess.run([str(root/'tests'/'extract-registry.py'),str(helper)],check=True,stdout=subprocess.DEVNULL,timeout=10)
    env=os.environ.copy(); env.update(
        DFR_STATE_ROOT=str(td/'state'), DFR_REGISTRY_DB=str(td/'state/database/registry.sqlite3'),
        DFR_BACKUP_DIR=str(td/'state/backups'), DFR_CONFIG_ROOT=str(td/'etc'),
        DFR_REGISTRY_RUNTIME_STATE=str(td/'runtime.json'), DFR_NFT='/bin/true', DFR_TC='/bin/true')
    def run(*args,check=True):
        return subprocess.run([sys.executable,str(helper),*map(str,args)],env=env,check=check,text=True,capture_output=True,timeout=10)
    run('init','--endpoint','198.51.100.10')
    version='v2.1.0'
    payload=td/'client.sh'; payload.write_text('#!/usr/bin/env bash\nreadonly APP_VERSION="v2.1.0"\n')
    os.chmod(payload,0o755); digest=hashlib.sha256(payload.read_bytes()).hexdigest()
    key=td/'key'; sig=td/'sig'; manifest_file=td/'manifest.json'
    key.write_text('-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VwBCIEIPe0Rtj3wXPspQY70+cjBb7lC0XLhvB8uZeK6kYtcimq\n-----END PRIVATE KEY-----\n')
    manifest={'format':'dragon-fruit-relay-ingress-release','format_version':1,'version':version,'sha256':digest,'role':'ingress','minimum_control_protocol':1,'config_schema':1,'enrollment_token_version':1,'apply_mode':'safe-rollback','reconcile_required':True,'capabilities':['release-sha-report-v1'],'created_at':1}
    canonical=json.dumps(manifest,sort_keys=True,separators=(',',':')); manifest_file.write_text(canonical)
    subprocess.run(['openssl','pkeyutl','-sign','-rawin','-inkey',str(key),'-in',str(manifest_file),'-out',str(sig)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
    run('release-publish',version,'--payload',payload,'--signature',sig,'--sha256',digest,'--manifest-json',canonical,'--status','stable')
    psk='ab'*32
    run('upsert-connection','--name','first-client','--profile-index','1','--udp-port','45001','--tunnel-cidr','10.10.0.0/30','--xfrm-if','dfr0001','--xfrm-id','1001','--xfrm-mtu','1400','--ingress-xfrm-cidr','10.10.0.1/30','--egress-xfrm-cidr','10.10.0.2/30','--ingress-xfrm-ip','10.10.0.1','--egress-xfrm-ip','10.10.0.2','--ingress-id','ingress-first','--egress-id','egress-first','--psk',psk,'--dns-primary','1.1.1.1','--dns-secondary','8.8.8.8')
    db=sqlite3.connect(env['DFR_REGISTRY_DB']); db.row_factory=sqlite3.Row
    c=dict(db.execute('SELECT update_policy,desired_ingress_version,desired_ingress_source FROM connections WHERE name=?',('first-client',)).fetchone())
    st=dict(db.execute('SELECT update_target,update_sha256,update_status FROM ingress_state WHERE connection_name=?',('first-client',)).fetchone())
    assert c=={'update_policy':'auto','desired_ingress_version':'v2.1.0','desired_ingress_source':'auto'},c
    assert st['update_target']=='v2.1.0' and st['update_sha256']==digest and st['update_status']=='QUEUED',st
print('default Client software: bundled release bootstrap is STABLE; newly created connections are AUTO and immediately target the latest stable payload')
