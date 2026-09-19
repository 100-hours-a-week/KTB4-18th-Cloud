#!/usr/bin/env python3
import json
import subprocess
import sys
import time

command_id, instance_id = sys.argv[1:]
for _ in range(192):
    result = subprocess.run(['aws', 'ssm', 'get-command-invocation', '--command-id', command_id,
                             '--instance-id', instance_id, '--output', 'json'], capture_output=True, text=True)
    if result.returncode:
        if 'InvocationDoesNotExist' not in result.stderr:
            sys.exit(result.stderr)
    else:
        invocation = json.loads(result.stdout)
        status = invocation['Status']
        if status == 'Success':
            print('Deployment succeeded')
            print(invocation.get('StandardOutputContent', ''))
            sys.exit(0)
        if status not in ('Pending', 'InProgress', 'Delayed'):
            print(invocation.get('StandardOutputContent', ''))
            print(invocation.get('StandardErrorContent', ''), file=sys.stderr)
            sys.exit('Deployment failed: ' + status)
    time.sleep(5)
sys.exit('Timed out waiting for SSM. Check command ' + command_id + ' before retrying.')
