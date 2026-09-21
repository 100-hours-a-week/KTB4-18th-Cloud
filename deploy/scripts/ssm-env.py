#!/usr/bin/env python3
"""SSM JSON -> Compose raw env_file. Never interpolate secret values."""
import json
import os
import re
import sys
from pathlib import Path


def convert(parameters):
    values = {}
    for item in parameters:
        key = item['Name'].rsplit('/', 1)[-1]
        value = item['Value']
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', key) or key in values:
            raise ValueError('Invalid or duplicate parameter key')
        if any(c in value for c in '\r\n\x00'):
            raise ValueError('Multiline values must be provided as a file, not an env parameter')
        values[key] = value
    if not values:
        raise ValueError('No SSM parameters found')
    return ''.join(f'{k}={v}\n' for k, v in sorted(values.items()))


if __name__ == '__main__':
    os.umask(0o077)
    output = Path(sys.argv[1])
    payload = convert(json.load(sys.stdin)['Parameters'])
    temporary = output.with_suffix('.tmp')
    temporary.write_text(payload)
    temporary.chmod(0o600)
    temporary.replace(output)
