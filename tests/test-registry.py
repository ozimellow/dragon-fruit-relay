#!/usr/bin/env python3
from pathlib import Path
import json, os, sqlite3, subprocess, tempfile, sys
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='dfr-registry-test-') as td:
    td=Path(td); helper=td/'registry.py'
    subprocess.run([str(root/'tests'/'extract-registry.py'),str(helper)],check=True,stdout=subprocess.DEVNULL)
    env=os.environ.copy(); env.update(DFR_STATE_ROOT=str(td/'state'),DFR_REGISTRY_DB=str(td/'state/database/registry.sqlite3'),DFR_BACKUP_DIR=str(td/'state/backups'),DFR_CONFIG_ROOT=str(td/'etc'),DFR_REGISTRY_RUNTIME_STATE=str(td/'runtime.json'),DFR_NFT='/bin/true',DFR_TC='/bin/true')
    def run(*args): return subprocess.run([sys.executable,str(helper),*map(str,args)],env=env,check=True,text=True,capture_output=True).stdout.strip()
    run('init','--endpoint','193.11.160.92')
    contract=json.loads(run('schema-contract'))
    expected_tables={
      'meta','hub','server_policy','server_endpoint_fallbacks','connections','subscriptions','usage','audit','ingress_state','control_nonces','enrollment_tokens','config_pending','software_releases','software_release_usage'
    }
    assert contract['product']=='dragon-fruit-relay' and contract['product_lineage']=='standalone-dfr' and contract['registry_schema']==1
    assert set(contract['tables'])==expected_tables
    db=Path(env['DFR_REGISTRY_DB']); c=sqlite3.connect(db)
    actual={r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")}
    assert actual==expected_tables,(actual,expected_tables)
    for table,cols in contract['tables'].items():
        got=[r[1] for r in c.execute(f'PRAGMA table_info({table})')]
        assert got==cols,(table,got,cols)
    meta=c.execute('SELECT key,value FROM meta ORDER BY key').fetchall(); assert meta==[('product','dragon-fruit-relay'),('product_lineage','standalone-dfr'),('registry_schema','1')]
    c.execute('CREATE TABLE unexpected_schema_probe(id INTEGER)'); c.commit()
    bad=subprocess.run([sys.executable,str(helper),'fleet-snapshot','--json'],env=env,text=True,capture_output=True)
    assert bad.returncode != 0 and 'table set mismatch' in (bad.stderr+bad.stdout)
    c.execute('DROP TABLE unexpected_schema_probe'); c.commit()
    empty=json.loads(run('fleet-snapshot','--json')); assert empty['summary']['total']==0 and empty['summary']['unknown']==0
    assert run('server-endpoint')=='193.11.160.92'
    assert run('server-endpoint-set','relay.example.com')=='relay.example.com'
    assert run('server-endpoint')=='relay.example.com'
    assert run('server-endpoint-set','198.51.100.44')=='198.51.100.44'
    psk='ab'*32
    run('upsert-connection','--name','client-1','--profile-index','1','--udp-port','45001','--tunnel-cidr','10.10.0.0/30','--xfrm-if','dfr0001','--xfrm-id','1001','--xfrm-mtu','1400','--ingress-xfrm-cidr','10.10.0.1/30','--egress-xfrm-cidr','10.10.0.2/30','--ingress-xfrm-ip','10.10.0.1','--egress-xfrm-ip','10.10.0.2','--ingress-id','dragon-fruit-relay-ingress-client-1','--egress-id','dragon-fruit-relay-egress-client-1','--psk',psk,'--dns-primary','1.1.1.1','--dns-secondary','8.8.8.8')
    run('set','client-1','--quota','10GB','--upload-mbps','20','--download-mbps','50')
    run('server-speed','--upload-mbps','100','--download-mbps','200')
    shown=json.loads(run('show','client-1','--json')); assert shown['name']=='client-1' and shown['quota_bytes']==10*1000**3 and shown['max_upload_mbps']==20 and shown['max_download_mbps']==50
    creds=run('management-credentials','client-1'); assert 'CONNECTION_UUID\t' in creds and 'CONTROL_KEY\t' in creds
    token_hash='11'*32
    token_id=run('token-record','client-1','--token-hash',token_hash,'--token-version','1','--expires-at','4102444800'); assert token_id.isdigit()
    rejected=subprocess.run([sys.executable,str(helper),'token-record','client-1','--token-hash','22'*32,'--token-version','2','--expires-at','4102444800'],env=env,text=True,capture_output=True)
    assert rejected.returncode != 0 and 'unsupported enrollment token version' in (rejected.stderr+rejected.stdout)
    assert run('token-consume','--token-hash',token_hash)=='client-1'
    run('suspend','client-1'); assert json.loads(run('show','client-1','--json'))['state']=='SUSPENDED'
    run('resume','client-1'); assert json.loads(run('show','client-1','--json'))['state']=='ACTIVE'
    secrets_dir=Path(env['DFR_CONFIG_ROOT'])/'secrets'; secrets_dir.mkdir(parents=True,exist_ok=True)
    key=secrets_dir/'ingress-update-ed25519.key'; pub=secrets_dir/'ingress-update-ed25519.pub'
    subprocess.run(['openssl','genpkey','-algorithm','Ed25519','-out',str(key)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    subprocess.run(['openssl','pkey','-in',str(key),'-pubout','-out',str(pub)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    backup=td/'roundtrip.dfrbak'; created=run('backup-create','--output',backup); assert Path(created)==backup and backup.is_file()
    assert run('backup-verify',backup).startswith('OK\t198.51.100.44\t')
    run('server-endpoint-set','203.0.113.77'); run('remove-connection','client-1'); assert run('list-names')==''
    assert run('backup-restore',backup)=='198.51.100.44'
    restored=json.loads(run('show','client-1','--json')); assert restored['name']=='client-1' and restored['quota_bytes']==10*1000**3
    assert run('server-endpoint')=='198.51.100.44'
    run('remove-connection','client-1'); assert run('list-names')==''
    c.close()
print('registry contract: exact schema, strict rejection, empty fleet, endpoints, policy, suspension, backup/restore, connection lifecycle OK')
