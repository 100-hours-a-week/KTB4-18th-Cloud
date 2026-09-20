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


def prepare(root, slot):
    mysql = read_env(root / 'mysql.env')
    postgres = read_env(root / 'postgres.env')
    for config, required in [(mysql, ['MYSQL_DATABASE', 'MYSQL_USER', 'MYSQL_PASSWORD', 'MYSQL_ROOT_PASSWORD']),
                             (postgres, ['POSTGRES_DB', 'POSTGRES_USER', 'POSTGRES_PASSWORD', 'POSTGRES_APP_USER', 'POSTGRES_APP_PASSWORD'])]:
        for key in required:
            if not config.get(key):
                raise ValueError('Required DB setting is missing: ' + key)
        for key in required:
            if not key.endswith('PASSWORD') and not re.fullmatch(r'[a-zA-Z_][a-zA-Z0-9_]*', config[key]):
                raise ValueError('Use an alphanumeric DB/user identifier: ' + key)
    if mysql['MYSQL_USER'] == 'root':
        raise ValueError('MYSQL_USER must be an application user, not root')
    if postgres['POSTGRES_APP_USER'] == postgres['POSTGRES_USER']:
        raise ValueError('Postgres application and admin users must differ')
    connections = {
        'backend': {
            'PROD_DB_URL': 'jdbc:mysql://mysql:3306/' + mysql['MYSQL_DATABASE'],
            'PROD_DB_USERNAME': mysql['MYSQL_USER'],
            'PROD_DB_PASSWORD': mysql['MYSQL_PASSWORD'],
        },
        'ai': {
            'DATABASE_URL': 'postgresql+psycopg://{}:{}@postgres:5432/{}'.format(
                quote(postgres['POSTGRES_APP_USER'], safe=''),
                quote(postgres['POSTGRES_APP_PASSWORD'], safe=''),
                quote(postgres['POSTGRES_DB'], safe=''),
            ),
            'PGHOST': 'postgres', 'PGPORT': '5432',
            'PGDATABASE': postgres['POSTGRES_DB'], 'PGUSER': postgres['POSTGRES_APP_USER'],
            'PGPASSWORD': postgres['POSTGRES_APP_PASSWORD'],
        },
    }
    for service, settings in connections.items():
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
    prepare(Path(sys.argv[1]), sys.argv[2])
