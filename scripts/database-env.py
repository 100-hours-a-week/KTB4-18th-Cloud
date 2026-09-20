#!/usr/bin/env python3
"""Generate application DB connection settings from the same local DB credentials."""
import os
from pathlib import Path
import re
import sys
from urllib.parse import quote


def read_env(path):
    values = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        key, value = line.split('=', 1)
        if key in values:
            raise ValueError('Duplicate environment key: ' + key)
        values[key] = value
    return values


def prepare(root, slot, service):
    requirements = {
        'backend': ('mysql.env', ['MYSQL_DATABASE', 'MYSQL_USER', 'MYSQL_PASSWORD', 'MYSQL_ROOT_PASSWORD']),
        'ai': ('postgres.env', ['POSTGRES_DB', 'POSTGRES_USER', 'POSTGRES_PASSWORD',
                               'POSTGRES_APP_USER', 'POSTGRES_APP_PASSWORD']),
    }
    filename, required = requirements[service]
    config = read_env(root / filename)
    for key in required:
        if not config.get(key):
            raise ValueError('Required DB setting is missing: ' + key)
    for key in required:
        if not key.endswith('PASSWORD') and not re.fullmatch(r'[a-zA-Z_][a-zA-Z0-9_]*', config[key]):
            raise ValueError('Use an alphanumeric DB/user identifier: ' + key)
    if service == 'backend' and config['MYSQL_USER'] == 'root':
        raise ValueError('MYSQL_USER must be an application user, not root')
    if service == 'ai' and config['POSTGRES_APP_USER'] == config['POSTGRES_USER']:
        raise ValueError('Postgres application and admin users must differ')
    if service == 'backend':
        settings = {
            'PROD_DB_URL': 'jdbc:mysql://mysql:3306/' + config['MYSQL_DATABASE'],
            'PROD_DB_USERNAME': config['MYSQL_USER'],
            'PROD_DB_PASSWORD': config['MYSQL_PASSWORD'],
        }
    else:
        settings = {
            'DATABASE_URL': 'postgresql+psycopg://{}:{}@postgres:5432/{}'.format(
                quote(config['POSTGRES_APP_USER'], safe=''),
                quote(config['POSTGRES_APP_PASSWORD'], safe=''),
                quote(config['POSTGRES_DB'], safe=''),
            ),
            'PGHOST': 'postgres', 'PGPORT': '5432',
            'PGDATABASE': config['POSTGRES_DB'], 'PGUSER': config['POSTGRES_APP_USER'],
            'PGPASSWORD': config['POSTGRES_APP_PASSWORD'],
        }
    path = root / (service + '-' + slot + '.env')
    values = read_env(path)
    values.update(settings)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(''.join(k + '=' + v + '\n' for k, v in sorted(values.items())))
    temporary.chmod(0o600)
    temporary.replace(path)


if __name__ == '__main__':
    os.umask(0o077)
    if sys.argv[2] not in ('blue', 'green'):
        raise ValueError('Invalid slot')
    if len(sys.argv) != 4 or sys.argv[3] not in ('backend', 'ai'):
        raise ValueError('Service must be backend or ai')
    prepare(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
