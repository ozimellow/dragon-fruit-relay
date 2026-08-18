#!/usr/bin/env python3
from pathlib import Path
import hashlib,hmac,importlib.util,json,os,sqlite3,subprocess,sys,tempfile,time

root=Path(__file__).resolve().parents[1]
egress=(root/'main-engine'/'dragon-fruit-relay-egress.sh').read_text()

def heredoc(text, opener, marker):
    start=text.index(opener)
    body=text[start:].split('\n',1)[1]
    return body.split('\n'+marker+'\n',1)[0]+'\n'

server=heredoc(egress,"cat > \"$CONTROL_RESPONDER\" <<'PY_DFR_CONTROL'",'PY_DFR_CONTROL')
server=server.replace('__DFR_CONTROL_PORTS__','39893').replace('__DFR_TARGET_SUBSCRIPTION_PORT__','39892').replace('__DFR_TARGET_CONTROL_PORT__','39893')

with tempfile.TemporaryDirectory(prefix='dfr-config-tx-') as raw:
    td=Path(raw); helper=td/'registry.py'; server_path=td/'control.py'
    subprocess.run([str(root/'tests'/'extract-registry.py'),str(helper)],check=True,stdout=subprocess.DEVNULL)
    env=os.environ.copy(); env.update(
        DFR_STATE_ROOT=str(td/'state'),DFR_REGISTRY_DB=str(td/'state/database/registry.sqlite3'),
        DFR_BACKUP_DIR=str(td/'state/backups'),DFR_CONFIG_ROOT=str(td/'etc'),
        DFR_REGISTRY_RUNTIME_STATE=str(td/'runtime.json'),DFR_NFT='/bin/true',DFR_TC='/bin/true')
    def reg(*args,check=True):
        return subprocess.run([sys.executable,str(helper),*map(str,args)],env=env,check=check,text=True,capture_output=True)
    reg('init','--endpoint','193.11.160.92')
    reg('upsert-connection','--name','client-1','--profile-index','1','--udp-port','45001',
        '--tunnel-cidr','10.10.0.0/30','--xfrm-if','dfr0001','--xfrm-id','1001','--xfrm-mtu','1400',
        '--ingress-xfrm-cidr','10.10.0.1/30','--egress-xfrm-cidr','10.10.0.2/30',
        '--ingress-xfrm-ip','10.10.0.1','--egress-xfrm-ip','10.10.0.2',
        '--ingress-id','dfr-ingress-client-1','--egress-id','dfr-egress-client-1',
        '--psk','ab'*32,'--dns-primary','1.1.1.1','--dns-secondary','8.8.8.8')
    db=Path(env['DFR_REGISTRY_DB'])
    with sqlite3.connect(db) as c:
        cu,key=c.execute("SELECT connection_uuid,control_key FROM connections WHERE name='client-1'").fetchone()
        c.execute("UPDATE ingress_state SET enrollment_token_hash=?,bootstrap_psk_state='enrolled' WHERE connection_name='client-1'",('33'*32,))

    # Stage a real registry candidate and simulate the Server coordinator reaching APPLYING.
    txid=reg('config-stage','client-1','--xfrm-mtu','1500').stdout.strip()
    assert txid
    reg('config-mark','client-1',txid,'PREPARED','--prepared-at',int(time.time()),'--egress-apply-at',int(time.time()),'--apply-at',int(time.time()),'--rollback-at',int(time.time())+60)
    reg('config-mark','client-1',txid,'APPLYING')

    server_path.write_text(server)
    spec=importlib.util.spec_from_file_location('dfr_config_server',server_path)
    srv=importlib.util.module_from_spec(spec); spec.loader.exec_module(srv)
    srv.DB=db; srv.UPDATE_PUBLIC_KEY=td/'missing.pub'; srv.TX_HELPER='/bin/true'

    # The Client success report must atomically commit authoritative values AND
    # remove the temporary transaction. COMMITTED must never linger as pseudo-work.
    payload={
        'ingress_version':'v2.1.0','ingress_sha256':'22'*32,'health':'HEALTHY',
        'update_status':'CURRENT','action_name':'configuration','action_status':'RUNNING',
        'action_message':'coordinated configuration change is applying',
        'client_endpoint':'193.11.160.92','client_capabilities':['server-endpoint-sync-v2'],
        'config_result':'success','config_transaction_id':txid,
    }
    req={'protocol':srv.PROTOCOL,'connection_uuid':cu,'timestamp':int(time.time()),'nonce':'c'*32,
         'op':'report','enrollment_token_hash':'33'*32,'payload':payload}
    req['mac']=hmac.new(bytes.fromhex(key),srv.req_material(req),hashlib.sha256).hexdigest()
    _auth,out=srv.handle(req,'10.10.0.2','10.10.0.1')
    assert not out.get('transaction'), out.get('transaction')
    with sqlite3.connect(db) as c:
        c.row_factory=sqlite3.Row
        conn=c.execute("SELECT xfrm_mtu FROM connections WHERE name='client-1'").fetchone()
        pending=c.execute("SELECT * FROM config_pending WHERE connection_name='client-1'").fetchone()
        state=c.execute("SELECT action_name,action_status,action_message FROM ingress_state WHERE connection_name='client-1'").fetchone()
        assert conn['xfrm_mtu']==1500, dict(conn)
        assert pending is None, dict(pending) if pending else None
        assert state['action_name']=='configuration' and state['action_status']=='SUCCEEDED', dict(state)
        assert 'committed' in state['action_message'], dict(state)

        # Simulate a stale COMMITTED row left by an older v2.1.0 build. A new
        # edit must safely prune it instead of remaining permanently blocked.
        now=int(time.time())
        snapshot=json.dumps({'udp_port':45001,'xfrm_mtu':1500,'dns_primary':'1.1.1.1','dns_secondary':'8.8.8.8','psk':'ab'*32},sort_keys=True)
        c.execute("INSERT INTO config_pending(connection_name,transaction_id,state,previous_json,candidate_json,created_at,updated_at,kind) VALUES(?,?,?,?,?,?,?,?)",
                  ('client-1','11111111-1111-1111-1111-111111111111','COMMITTED',snapshot,snapshot,now,now,'manual'))
        c.commit()
    next_tx=reg('config-stage','client-1','--xfrm-mtu','1600').stdout.strip()
    assert next_tx and next_tx!='11111111-1111-1111-1111-111111111111'
    with sqlite3.connect(db) as c:
        rows=c.execute("SELECT transaction_id,state FROM config_pending WHERE connection_name='client-1'").fetchall()
        assert rows==[(next_tx,'PENDING')], rows

    # Server coordinators must run outside the CONTROL responder cgroup.
    calls=[]
    real_run=srv.subprocess.run
    class CP:
        returncode=0; stderr=''
    def fake_run(argv,**kwargs):
        calls.append(list(argv)); return CP()
    srv.subprocess.run=fake_run
    srv.launch_config_transaction('client-1','22222222-2222-2222-2222-222222222222',100,200)
    srv.subprocess.run=real_run
    assert calls and calls[0][0]=='systemd-run', calls
    assert '--collect' in calls[0] and '--no-block' in calls[0] and srv.TX_HELPER in calls[0], calls

# Generated coordinator must regard a vanished row as already resolved.
helper_body=heredoc(egress,"cat > \"$CONTROL_TX_HELPER\" <<'EOF_DFR_CONTROL_TX'",'EOF_DFR_CONTROL_TX')
assert '[[ -z "$state" ]] && exit 0' in helper_body
assert "COMMITTED) config_status='SYNCED'" in egress
print('configuration transaction contract: supervised coordinator, atomic commit/finalize, stale-COMMITTED recovery OK')
