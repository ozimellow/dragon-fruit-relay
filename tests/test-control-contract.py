#!/usr/bin/env python3
from pathlib import Path
import hashlib, hmac, importlib.util, json, os, sqlite3, subprocess, tempfile, time, types, sys, re

root=Path(__file__).resolve().parents[1]
egress=(root/'main-engine'/'dragon-fruit-relay-egress.sh').read_text()
ingress=(root/'main-engine'/'dragon-fruit-relay-ingress.sh').read_text()

def heredoc(text, opener, marker):
    start=text.index(opener)
    body=text[start:].split('\n',1)[1]
    return body.split('\n'+marker+'\n',1)[0]+'\n'

# Execute the generated Client report payload contract instead of merely grepping it.
agent=heredoc(ingress, "cat > \"$CONTROL_AGENT\" <<'PY_DFR_CONTROL_AGENT'", 'PY_DFR_CONTROL_AGENT')
mod=types.ModuleType('dfr_client_control_contract')
mod.__file__='<generated-client-control>'
exec(compile(agent,mod.__file__,'exec'),mod.__dict__)
mod.load_config=lambda: {'PEER_ENDPOINT':'relay.example.com'}
mod.read_update_state=lambda: {
    'UPDATE_STATE':'APPLYING','UPDATE_VERSION':'v2.1.0','UPDATE_SHA256':'11'*32,
    'UPDATE_ERROR':'','UPDATE_STARTED_AT':'101','UPDATE_FINISHED_AT':'0',
}
mod.read_action_state=lambda: {
    'ACTION_NAME':'reconcile','ACTION_STATE':'RUNNING','ACTION_MESSAGE':'refreshing',
    'ACTION_STARTED_AT':'102','ACTION_FINISHED_AT':'0',
}
mod.read_simple=lambda _p: {'ERROR':''}
mod.health=lambda: 'HEALTHY'
mod.engine_version=lambda: 'v2.1.0'
mod.engine_sha256=lambda: '22'*32
payload=mod.report_payload()
required={
    'update_status','update_target','update_sha256','update_error','update_started_at','update_finished_at',
    'action_name','action_status','action_message','action_started_at','action_finished_at',
    'client_endpoint','endpoint_error','client_capabilities','ingress_version','ingress_sha256','health',
}
assert required <= set(payload), sorted(required-set(payload))
for forbidden in ('server_endpoint','update_state','update_target_version','last_action','last_action_state'):
    assert forbidden not in payload, forbidden
assert payload['client_endpoint']=='relay.example.com'
assert 'server-endpoint-sync-v2' in payload['client_capabilities']

# Validate Client endpoint application orchestration: a changed endpoint invokes the
# managed engine, verifies persisted PEER_ENDPOINT, and immediately reports convergence.
state={'endpoint':'old.example.com','calls':[],'reports':0}
_real_subprocess_run=subprocess.run
mod.load_config=lambda: {'PEER_ENDPOINT':state['endpoint']}
mod.read_update_state=lambda: {}
mod.read_simple=lambda _p: {}
mod.report_best_effort=lambda extra=None: state.__setitem__('reports',state['reports']+1) or {'server_endpoint':'new.example.com'}
class CP:
    returncode=0; stdout=''
def fake_run(argv,**kwargs):
    state['calls'].append(list(argv))
    if '_managed-set-server-endpoint' in argv:
        state['endpoint']=argv[-1]
    return CP()
mod.subprocess.run=fake_run
with tempfile.TemporaryDirectory(prefix='dfr-client-endpoint-state-') as td:
    mod.ENDPOINT_STATE=Path(td)/'endpoint.conf'
    out=mod.process_server_endpoint({'server_endpoint':'new.example.com','transaction':{}})
assert state['endpoint']=='new.example.com'
assert any('_managed-set-server-endpoint' in c and c[-1]=='new.example.com' for c in state['calls']), state['calls']
assert state['reports']>=2, state

# A recent failed endpoint activation normally backs off, but an explicit Server
# Synchronize (pending_action=reconcile) must bypass that backoff immediately.
retry={'endpoint':'old.example.com','calls':[]}
mod.load_config=lambda: {'PEER_ENDPOINT':retry['endpoint']}
mod.read_update_state=lambda: {}
mod.report_best_effort=lambda extra=None: {'server_endpoint':'new.example.com','pending_action':'reconcile','transaction':{}}
def retry_run(argv,**kwargs):
    retry['calls'].append(list(argv))
    if '_managed-set-server-endpoint' in argv:
        retry['endpoint']=argv[-1]
    return CP()
mod.subprocess.run=retry_run
with tempfile.TemporaryDirectory(prefix='dfr-client-endpoint-retry-') as td:
    mod.ENDPOINT_STATE=Path(td)/'endpoint.conf'
    mod.write_simple(mod.ENDPOINT_STATE,{'AT':int(time.time()),'DESIRED':'new.example.com','ERROR':'previous activation failed'})
    mod.process_server_endpoint({'server_endpoint':'new.example.com','pending_action':'reconcile','transaction':{}})
assert any('_managed-set-server-endpoint' in c for c in retry['calls']), retry

subprocess.run=_real_subprocess_run
mod.subprocess.run=_real_subprocess_run

# A desired software version is advertised continuously by managed Servers. It must
# not suppress endpoint/reconcile processing when the Client is already current.
calls={'endpoint':0,'reconcile':0,'report':0}
remote_current={
    'registry_schema':1,'runtime_api':1,'desired_ingress_version':'v2.1.0',
    'server_endpoint':'new.example.com','transaction':None,
}
mod.load_config=lambda: {'MANAGED_CONTROL':'yes','PEER_ENDPOINT':'old.example.com'}
mod.request=lambda op,payload: dict(remote_current) if op=='poll' else dict(remote_current)
mod.reconcile_incomplete_local_tx=lambda remote: remote
mod.process_update=lambda remote: remote
mod.read_update_state=lambda: {'UPDATE_STATE':'CURRENT'}
mod.process_server_endpoint=lambda remote: calls.__setitem__('endpoint',calls['endpoint']+1) or remote
mod.process_reconcile=lambda remote: calls.__setitem__('reconcile',calls['reconcile']+1) or remote
mod.report=lambda extra=None: calls.__setitem__('report',calls['report']+1) or {}
with tempfile.TemporaryDirectory(prefix='dfr-control-priority-') as td:
    mod.UPDATE_DIR=Path(td)
    assert mod.once()==0
assert calls['endpoint']==1 and calls['reconcile']==1, calls

# Extract and execute the generated Server CONTROL handler with a real schema-1 DB.
server=heredoc(egress, "cat > \"$CONTROL_RESPONDER\" <<'PY_DFR_CONTROL'", 'PY_DFR_CONTROL')
server=server.replace('__DFR_CONTROL_PORTS__','39893').replace('__DFR_TARGET_SUBSCRIPTION_PORT__','39892').replace('__DFR_TARGET_CONTROL_PORT__','39893')
with tempfile.TemporaryDirectory(prefix='dfr-control-contract-') as raw:
    td=Path(raw); helper=td/'registry.py'; server_path=td/'control.py'
    subprocess.run([str(root/'tests'/'extract-registry.py'),str(helper)],check=True,stdout=subprocess.DEVNULL)
    env=os.environ.copy(); env.update(
        DFR_STATE_ROOT=str(td/'state'),DFR_REGISTRY_DB=str(td/'state/database/registry.sqlite3'),
        DFR_BACKUP_DIR=str(td/'state/backups'),DFR_CONFIG_ROOT=str(td/'etc'),
        DFR_REGISTRY_RUNTIME_STATE=str(td/'runtime.json'),DFR_NFT='/bin/true',DFR_TC='/bin/true')
    def reg(*args):
        return subprocess.run([sys.executable,str(helper),*map(str,args)],env=env,check=True,text=True,capture_output=True).stdout.strip()
    reg('init','--endpoint','193.11.160.92')
    reg('upsert-connection','--name','client-1','--profile-index','1','--udp-port','45001',
        '--tunnel-cidr','10.10.0.0/30','--xfrm-if','dfr0001','--xfrm-id','1001','--xfrm-mtu','1400',
        '--ingress-xfrm-cidr','10.10.0.1/30','--egress-xfrm-cidr','10.10.0.2/30',
        '--ingress-xfrm-ip','10.10.0.1','--egress-xfrm-ip','10.10.0.2',
        '--ingress-id','dfr-ingress-client-1','--egress-id','dfr-egress-client-1',
        '--psk','ab'*32,'--dns-primary','1.1.1.1','--dns-secondary','8.8.8.8')
    db=Path(env['DFR_REGISTRY_DB'])
    with sqlite3.connect(db) as c:
        row=c.execute("SELECT connection_uuid,control_key FROM connections WHERE name='client-1'").fetchone()
        cu,key=row
        c.execute("UPDATE ingress_state SET enrollment_token_hash=?,bootstrap_psk_state='enrolled' WHERE connection_name='client-1'",('33'*32,))
    server_path.write_text(server)
    spec=importlib.util.spec_from_file_location('dfr_server_control_contract',server_path)
    srv=importlib.util.module_from_spec(spec); spec.loader.exec_module(srv)
    srv.DB=db; srv.UPDATE_PUBLIC_KEY=td/'missing.pub'; srv.TX_HELPER='/bin/true'
    body=dict(payload)
    body.update({'client_endpoint':'relay.example.com','health':'HEALTHY','update_status':'CURRENT','action_status':'SUCCEEDED'})
    req={
        'protocol':srv.PROTOCOL,'connection_uuid':cu,'timestamp':int(time.time()),'nonce':'n'*32,
        'op':'report','enrollment_token_hash':'33'*32,'payload':body,
    }
    req['mac']=hmac.new(bytes.fromhex(key),srv.req_material(req),hashlib.sha256).hexdigest()
    srv.handle(req,'10.10.0.2','10.10.0.1')
    with sqlite3.connect(db) as c:
        c.row_factory=sqlite3.Row
        r=c.execute("SELECT client_endpoint,health,update_status,action_status,client_capabilities_json FROM ingress_state WHERE connection_name='client-1'").fetchone()
        assert r['client_endpoint']=='relay.example.com', dict(r)
        assert r['health']=='HEALTHY' and r['update_status']=='CURRENT' and r['action_status']=='SUCCEEDED', dict(r)
        assert 'server-endpoint-sync-v2' in json.loads(r['client_capabilities_json']), dict(r)

# Transport contract: management listeners are tunnel-scoped and firewall rules are
# symmetrical for install/remove, including peer-health ICMP.
for needle in (
    'iptables -C INPUT -i "$XFRM_IF" -s "$INGRESS_XFRM_IP/32" -d "$EGRESS_XFRM_IP/32" -p tcp',
    '--dports "$ports"',
    'client_rule_comment "$name" management-in',
    'client_rule_comment "$name" management-out',
    'client_rule_comment "$name" peer-ping-in',
    'client_rule_comment "$name" peer-ping-out',
    'client_management_listeners_ready ()',
    'wait_client_management_listeners ()',
):
    assert needle in egress, needle
for kind in ('management-in','management-out','peer-ping-in','peer-ping-out'):
    assert f'delete_iptables_rules_by_comment filter "$(client_rule_comment "$name" {kind})"' in egress, kind

# Synchronize is an operational recovery path, not a registry-only requeue. It must
# refresh both responders, restore per-Client tunnel rules, verify listeners, and
# only then reconcile endpoint state. Client repair uses the same contract.
for needle in (
    'refresh_client_management_plane ()',
    'write_subscription_responder || {',
    'write_control_plane_files || {',
    'apply_client_network_rules "$name"',
    'wait_client_management_listeners "$name"',
    'refresh_client_management_plane || management_ok=no',
    'registry_command server-endpoint-reconcile',
    "'Verify Client endpoint synchronization'",
    "'Synchronize Client endpoint drift now'",
    "'Endpoint state was reconciled against the active Server endpoint.'",
    "'Every enrolled Client reports the active Server endpoint.'",
):
    assert needle in egress, needle
repair=egress[egress.index('repair_hub_client ()'):egress.index('require_root_and_platform ()')]
assert 'wait_client_management_listeners "$name"' in repair

# Runtime endpoint retarget contract: a resolved peer-IP change must force a managed
# reconnect; FQDN DNS changes detected by health monitoring do the same.
for needle in (
    '[[ "$resolved" == "$old_ip" ]] || force_reconnect=yes',
    'managed_reconcile "$force_reconnect"',
    'DFR_INTERNAL_NO_MAIN_LOCK=1 /usr/local/sbin/dragon-fruit-relay _managed-reconcile yes',
    '# DFR_CONTROL_AGENT_REPORT_CONTRACT_V2',
):
    assert needle in ingress, needle

print('CONTROL/endpoint contract: report/poll state machine, Server persistence, operational sync repair, management firewall/listeners, forced retarget OK')
