#!/usr/bin/env python3
from pathlib import Path
from types import SimpleNamespace
from contextlib import redirect_stdout
import importlib.util, io, json, os, sqlite3, subprocess, tempfile, time, uuid

root=Path(__file__).resolve().parents[1]
CAP='server-endpoint-sync-v2'
ORIGINAL_PATH=os.environ.get('PATH','')


def _capture(fn, args=None):
    out=io.StringIO()
    with redirect_stdout(out):
        fn(args if args is not None else SimpleNamespace())
    return out.getvalue().strip()


def make_registry(td: Path, endpoint: str, with_client=True):
    helper=td/'registry.py'
    subprocess.run([str(root/'tests'/'extract-registry.py'),str(helper)],check=True,stdout=subprocess.DEVNULL)
    fakebin=td/'bin'; fakebin.mkdir(parents=True,exist_ok=True)
    systemctl=fakebin/'systemctl'; systemctl.write_text('#!/bin/sh\nexit 0\n'); systemctl.chmod(0o755)
    env={
        'PATH':str(fakebin)+os.pathsep+ORIGINAL_PATH,
        'DFR_STATE_ROOT':str(td/'state'),
        'DFR_REGISTRY_DB':str(td/'state/database/registry.sqlite3'),
        'DFR_BACKUP_DIR':str(td/'state/backups'),
        'DFR_CONFIG_ROOT':str(td/'etc'),
        'DFR_REGISTRY_RUNTIME_STATE':str(td/'runtime.json'),
        'DFR_NFT':'/bin/true', 'DFR_TC':'/bin/true',
    }
    os.environ.update(env)
    spec=importlib.util.spec_from_file_location(f'dfr_registry_{uuid.uuid4().hex}',helper)
    mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    _capture(mod.cmd_init,SimpleNamespace(endpoint=endpoint,force=False))
    db=Path(env['DFR_REGISTRY_DB'])
    if with_client:
        _capture(mod.cmd_upsert,SimpleNamespace(
            name='client-1',profile_index=1,created_at=None,udp_port=45001,
            tunnel_cidr='10.10.0.0/30',xfrm_if='dfr0001',xfrm_id=1001,xfrm_mtu=1400,
            ingress_xfrm_cidr='10.10.0.1/30',egress_xfrm_cidr='10.10.0.2/30',
            ingress_xfrm_ip='10.10.0.1',egress_xfrm_ip='10.10.0.2',
            ingress_id='dfr-ingress-client-1',egress_id='dfr-egress-client-1',
            psk='ab'*32,dns_primary='1.1.1.1',dns_secondary='8.8.8.8'))
        report_endpoint(db,endpoint)
    return mod,db


def status(mod):
    with mod.conn() as c:
        mod.init_schema(c)
        return mod.endpoint_transition_status(c)


def reconcile(mod):
    return json.loads(_capture(mod.cmd_server_endpoint_reconcile))


def set_endpoint(mod,target):
    return _capture(mod.cmd_server_endpoint_set,SimpleNamespace(endpoint=target))


def retire_previous(mod):
    return _capture(mod.cmd_server_endpoint_retire_previous)


def report_endpoint(db: Path, endpoint: str, *, error=None):
    with sqlite3.connect(db) as c:
        c.execute("""
          UPDATE ingress_state
             SET client_endpoint=?,endpoint_error=?,last_seen_at=?,health='HEALTHY',
                 client_capabilities_json=?,bootstrap_psk_state='enrolled',
                 action_name='reconcile',action_status='SUCCEEDED'
           WHERE connection_name='client-1'
        """,(endpoint,error,int(time.time()),json.dumps([CAP])))
        c.execute("UPDATE connections SET pending_action=NULL WHERE name='client-1'")


def endpoint_work(mod):
    payload=json.loads(_capture(mod.cmd_fleet_snapshot,SimpleNamespace(json=True)))
    return [w for w in payload.get('active_work',[]) if str(w.get('area','')).upper()=='ENDPOINT']


def assert_baseline(mod, endpoint: str, mode: str):
    s=status(mod)
    assert s['server_endpoint']==endpoint, s
    assert s['endpoint_mode']==mode, s
    assert s['migration_active'] is False, s
    assert s['migration_state']=='IDLE', s
    assert s['synchronization_state']=='SYNCED', s
    assert s['fallback_count']==0, s
    assert s['synced_clients']==1 and s['blocking_clients']==0, s
    assert s['clients'][0]['state']=='SYNCED', s
    assert endpoint_work(mod)==[], endpoint_work(mod)


def assert_idle_drift_repair(mod, db, endpoint):
    report_endpoint(db,'198.51.100.250')
    s=status(mod)
    assert s['migration_state']=='IDLE' and s['migration_active'] is False, s
    assert s['synchronization_state']=='ATTENTION' and s['blocking_clients']==1, s
    assert s['clients'][0]['state']=='PENDING', s
    work=endpoint_work(mod)
    assert work and any('PENDING' in str(w.get('headline','')).upper() for w in work), work
    retry=reconcile(mod)
    assert retry['queue']['queued_refreshes'] >= 1, retry
    with sqlite3.connect(db) as c:
        assert c.execute("SELECT pending_action FROM connections WHERE name='client-1'").fetchone()[0]=='reconcile'
    report_endpoint(db,endpoint)
    retry=reconcile(mod)
    assert retry['status']['migration_state']=='IDLE', retry
    assert retry['status']['synchronization_state']=='SYNCED', retry
    assert endpoint_work(mod)==[]


def transition(mod, db, target: str, target_mode: str, check_work=False):
    old=status(mod)['server_endpoint']
    assert set_endpoint(mod,target)==target
    s=status(mod)
    assert s['migration_active'] is True, s
    assert s['migration_state']=='ACTIVE', s
    assert s['synchronization_state']=='ATTENTION', s
    assert s['fallback_server_endpoints']==[old], s
    assert s['server_endpoint']==target and s['endpoint_mode']==target_mode, s
    assert s['clients'][0]['state']=='PENDING', s
    if check_work:
        work=endpoint_work(mod)
        assert work and any('PENDING' in str(w.get('headline','')).upper() for w in work), work
        retry=reconcile(mod)
        assert retry['queue']['queued_refreshes'] >= 1, retry
        with sqlite3.connect(db) as c:
            assert c.execute("SELECT pending_action FROM connections WHERE name='client-1'").fetchone()[0]=='reconcile'

    report_endpoint(db,target)
    out=reconcile(mod); s=out['status']
    assert s['migration_active'] is True, s
    assert s['migration_state']=='READY TO FINISH', s
    assert s['synchronization_state']=='SYNCED', s
    assert s['fallback_server_endpoints']==[old], s
    assert s['safe_to_retire_fallbacks'] is True, s
    assert s['completed_at'], s
    assert s['clients'][0]['state']=='SYNCED', s
    assert endpoint_work(mod)==[]

    retired=retire_previous(mod)
    assert retired==old, retired
    final=status(mod)
    assert final['migration_active'] is False, final
    assert final['migration_state']=='IDLE', final
    assert final['synchronization_state']=='SYNCED', final
    assert final['fallback_server_endpoints']==[], final
    assert final['clients'][0]['state']=='SYNCED', final
    assert final['completed_at'], final


with tempfile.TemporaryDirectory(prefix='dfr-endpoint-ip-') as raw:
    mod,db=make_registry(Path(raw),'193.11.160.92')
    assert_baseline(mod,'193.11.160.92','IP')
    assert_idle_drift_repair(mod,db,'193.11.160.92')
    transition(mod,db,'relay.example.com','FQDN',check_work=True)  # IP -> FQDN
    transition(mod,db,'198.51.100.44','IP')                       # FQDN -> IP
    transition(mod,db,'203.0.113.77','IP')                        # IP -> IP
    transition(mod,db,'relay2.example.com','FQDN')                # IP -> FQDN
    transition(mod,db,'relay3.example.com','FQDN')                # FQDN -> FQDN

with tempfile.TemporaryDirectory(prefix='dfr-endpoint-fqdn-') as raw:
    mod,db=make_registry(Path(raw),'relay.example.com')
    assert_baseline(mod,'relay.example.com','FQDN')

with tempfile.TemporaryDirectory(prefix='dfr-endpoint-empty-') as raw:
    mod,db=make_registry(Path(raw),'193.11.160.92',with_client=False)
    s=status(mod); assert s['migration_state']=='IDLE' and s['synchronization_state']=='READY', s
    assert set_endpoint(mod,'relay.example.com')=='relay.example.com'
    s=status(mod); assert s['migration_state']=='READY TO FINISH' and s['blocking_clients']==0, s
    retire_previous(mod)
    s=status(mod); assert s['migration_state']=='IDLE' and s['synchronization_state']=='READY', s

print('endpoint synchronization: IDLE/SYNCED baseline + drift repair + explicit migration completion + IP/FQDN transitions OK')
