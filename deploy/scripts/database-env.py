#!/usr/bin/env python3
"""Generate application DB connection settings from the same local DB credentials."""
import os
from pathlib import Path
import re
import sys
from urllib.parse import quote


def read_env(path):
    """지정한 경로의 env 파일(.env)을 읽어 키-값 딕셔너리로 반환합니다."""
    values = {}
    for line in path.read_text().splitlines():
        # 빈 줄이거나 주석(#)인 경우 무시
        if not line or line.startswith('#'):
            continue
        key, value = line.split('=', 1)
        if key in values:
            raise ValueError('Duplicate environment key: ' + key)
        values[key] = value
    return values


def prepare(root, slot, service):
    """
    베이스 DB 설정을 읽어와 검증한 뒤,
    각 서비스(backend, ai)가 실행 시 참조할 런타임 환경변수 파일을 생성/업데이트합니다.
    """
    # 서비스별 필수 읽어와야 할 DB 설정 키 목록 정의
    requirements = {
        'backend': ('mysql.env', ['MYSQL_DATABASE', 'MYSQL_USER', 'MYSQL_PASSWORD', 'MYSQL_ROOT_PASSWORD']),
        'ai': ('postgres.env', ['POSTGRES_DB', 'POSTGRES_USER', 'POSTGRES_PASSWORD',
                               'POSTGRES_APP_USER', 'POSTGRES_APP_PASSWORD']),
    }
    filename, required = requirements[service]

    # 1. 베이스 DB 설정 파일 로드 및 필수 값 누락 여부 검증
    config = read_env(root / filename)
    for key in required:
        if not config.get(key):
            raise ValueError('Required DB setting is missing: ' + key)

    # 2. DB ID/사용자 이름 형식이 올바른지 알파벳/언더바 정규식 검증 (비밀번호 제외)
    for key in required:
        if not key.endswith('PASSWORD') and not re.fullmatch(r'[a-zA-Z_][a-zA-Z0-9_]*', config[key]):
            raise ValueError('Use an alphanumeric DB/user identifier: ' + key)

    # 3. 보안 정책 검증 (백엔드 root 계정 사용 금지, AI 관리자/앱 계정 분리 강제)
    if service == 'backend' and config['MYSQL_USER'] == 'root':
        raise ValueError('MYSQL_USER must be an application user, not root')
    if service == 'ai' and config['POSTGRES_APP_USER'] == config['POSTGRES_USER']:
        raise ValueError('Postgres application and admin users must differ')

    # 4. 서비스별 맞춤형 접속 URL 및 환경변수 세트 조립
    if service == 'backend':
        settings = {
            'PROD_DB_URL': 'jdbc:mysql://mysql:3306/' + config['MYSQL_DATABASE'],
            'PROD_DB_USERNAME': config['MYSQL_USER'],
            'PROD_DB_PASSWORD': config['MYSQL_PASSWORD'],
        }
    else:
        # AI 서비스는 특수문자가 포함된 비밀번호가 깨지지 않도록 quote()로 안전하게 인코딩
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

    # 5. 저장할 대상 환경변수 파일 경로 결정
    # AI는 공통 환경 파일을 사용하고, 백엔드는 Blue/Green 슬롯별 환경 파일을 사용합니다.
    path = root / ('ai.env' if service == 'ai' else service + '-' + slot + '.env')

    # 기존에 파일이 있다면 읽어온 뒤 새로운 설정값(settings)으로 갱신
    values = read_env(path) if path.exists() else {}
    values.update(settings)

    # 6. 임시 파일(.tmp)로 먼저 안전하게 기록한 뒤 권한 설정 후 교체 (Atomic Swap)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(''.join(k + '=' + v + '\n' for k, v in sorted(values.items())))
    temporary.chmod(0o600)  # 소유자만 읽고 쓸 수 있도록 엄격한 보안 권한 부여
    temporary.replace(path)


if __name__ == '__main__':
    # 스크립트 실행 시 기본 umask 설정 (파일 생성 시 권한 제어)
    os.umask(0o077)

    # 인자 개수 및 값 유효성 검사 (슬롯명: blue/green/single, 서비스명: backend/ai)
    if len(sys.argv) != 4 or sys.argv[2] not in ('blue', 'green', 'single') or sys.argv[3] not in ('backend', 'ai'):
        raise ValueError('Usage: database-env.py <root_path> <blue|green|single> <backend|ai>')

    prepare(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
