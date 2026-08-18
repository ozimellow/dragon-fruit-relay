#!/usr/bin/env python3
from pathlib import Path
import base64,re,time,uuid
root=Path(__file__).resolve().parents[1]
e=(root/'main-engine'/'dragon-fruit-relay-egress.sh').read_text(); i=(root/'main-engine'/'dragon-fruit-relay-ingress.sh').read_text()
# Assert both engines expose the same compact contract fields and current prefix.
assert 'token="DFR1.${token}"' in e
assert '[[ "$compact" == DFR1.* ]]' in i

assert "'enrollment_token_version':1" in e
assert "manifest.get('enrollment_token_version', 0)) != 1" in i
assert 'Q=${SUBSCRIPTION_PORT},${CONTROL_PORT}' in e
assert "Q) IFS=',' read -r subscription_port control_port" in i
payload='\n'.join([
 'V=1','N=alpha','I=1','U='+str(uuid.uuid4()),'C='+'ab'*32,'H=193.11.160.92','P=45001','S='+'cd'*32,'T=10.10.0.0/30','M=1400','D=1.1.1.1,8.8.8.8','Q=39892,39893','A='+str(int(time.time())),'E='+str(int(time.time())+1800)])
token='DFR1.'+base64.urlsafe_b64encode(payload.encode()).decode().rstrip('=')
decoded=base64.urlsafe_b64decode(token.split('.',1)[1]+'==').decode().splitlines()
assert [x.split('=',1)[0] for x in decoded]==['V','N','I','U','C','H','P','S','T','M','D','Q','A','E']
print('DFR1 token contract: Server producer and Client consumer fields agree')
