#!/usr/bin/env python3
"""Prepare a validated, pinned public-repository release for one EC2 via SSM."""
import json
import os
import re
import shlex


def command(env):
    instance = env['INSTANCE_ID']
    if not re.fullmatch(r'i-[a-f0-9]{8,17}', instance):
        raise ValueError('Invalid EC2 instance ID')
    repository = env['GITHUB_REPOSITORY']
    if repository != '100-hours-a-week/KTB4-18th-Cloud':
        raise ValueError('Unexpected infrastructure repository')
    sha = env['GITHUB_SHA']
    if not re.fullmatch(r'[a-f0-9]{40}', sha):
        raise ValueError('Invalid infrastructure commit SHA')
    images = [env[s + '_IMAGE'] for s in ['FRONTEND', 'BACKEND', 'AI']]
    for service, image in zip(['frontend', 'backend', 'ai'], images):
        pattern = (r'764788758503\.dkr\.ecr\.ap-northeast-2\.amazonaws\.com/mme-'
                   + service + r'(:[a-f0-9]{40}|@sha256:[a-f0-9]{64})')
        if not re.fullmatch(pattern, image):
            raise ValueError('Unexpected image URI for ' + service)
    stage = '/opt/meomuneum/releases/' + sha
    script = '''set -Eeuo pipefail
for tool in docker aws python3 curl tar flock; do command -v "$tool" >/dev/null; done
mkdir -p /opt/meomuneum/.state
cd /opt/meomuneum
exec 8>.state/install.lock
flock -n 8
exec 9>.state/deploy.lock
flock -n 9
'''
    script += 'stage=' + shlex.quote(stage) + '\nmkdir -p "$stage"\n'
    script += 'curl --fail --location --silent --show-error --max-time 120 ' + shlex.quote(
        'https://github.com/' + repository + '/archive/' + sha + '.tar.gz') + ' -o "$stage/source.tar.gz"\n'
    script += '''tar -xzf "$stage/source.tar.gz" -C "$stage" --strip-components=1
mkdir -p scripts nginx ai-router postgres/init
cp "$stage/compose.yml" compose.yml
cp "$stage/scripts/"*.sh "$stage/scripts/"*.py scripts/
cp "$stage/postgres/init/"* postgres/init/
for config in nginx/default.conf nginx/backend-upstream.conf ai-router/default.conf; do
  if [[ ! -f "$config" ]]; then cp "$stage/$config" "$config"; fi
done
flock -u 9
'''
    script += 'bash scripts/deploy.sh ' + ' '.join(map(shlex.quote, images)) + '\n'
    # AWS-RunShellScript uses /bin/sh; explicitly invoke bash for pipefail and arrays.
    wrapped = "bash <<'MME_DEPLOY_SCRIPT'\n" + script + 'MME_DEPLOY_SCRIPT\n'
    return {'DocumentName': 'AWS-RunShellScript', 'InstanceIds': [instance],
            'TimeoutSeconds': 60, 'Parameters': {'commands': [wrapped], 'executionTimeout': ['900']},
            'Comment': 'MME V1 ' + sha}


if __name__ == '__main__':
    print(json.dumps(command(os.environ)))
