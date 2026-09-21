"""배포 명령을 mock 처리하여 슬롯 전환·실패 복구·secret 보존을 검사합니다."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ssm_env', ROOT / 'deploy/scripts/ssm-env.py')
ssm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ssm)


class Parameters(unittest.TestCase):
    """SSM 값을 Compose raw env 형식으로 안전하게 바꾸는지 검사합니다."""
    def test_literal_secrets(self):
        value = ' spaces $TOKEN # \\ " \' = end '
        self.assertEqual(ssm.convert([{'Name': '/x/KEY', 'Value': value}]), 'KEY=' + value + '\n')

    def test_reject_ambiguous_values(self):
        for rows in [[], [{'Name': '/x/A', 'Value': 'a\nb'}],
                     [{'Name': '/x/A', 'Value': '1'}, {'Name': '/y/A', 'Value': '2'}],
                     [{'Name': '/x/INVALID-KEY', 'Value': '1'}]]:
            with self.assertRaises(ValueError):
                ssm.convert(rows)


class Deployment(unittest.TestCase):
    """실제 AWS/Docker 대신 명령 기록을 사용해 배포 상태 전이를 검사합니다."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        # 운영과 같은 deploy 하위 경로를 임시 프로젝트에 복사합니다.
        for folder in ['scripts', 'nginx']:
            shutil.copytree(ROOT / 'deploy' / folder, self.root / 'deploy' / folder)
        shutil.copy(ROOT / 'compose.yml', self.root)
        bindir = self.root / 'bin'
        bindir.mkdir()
        mock = '''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
name=Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['MOCK_LOG'],'a') as f: f.write(name+' '+ ' '.join(args)+'\\n')
if name=='aws':
 if args[0]=='ssm':
  settings={'KEY':'literal$VALUE#ok'}
  if args[args.index('--path')+1].endswith('/mysql'):
   settings={'MYSQL_DATABASE':'meomuneum','MYSQL_USER':'app','MYSQL_PASSWORD':'db$secret','MYSQL_ROOT_PASSWORD':'root-secret'}
  if args[args.index('--path')+1].endswith('/postgres'):
   settings={'POSTGRES_DB':'ai','POSTGRES_USER':'postgres','POSTGRES_PASSWORD':'admin-secret','POSTGRES_APP_USER':'ai','POSTGRES_APP_PASSWORD':'pg$secret!:@/'}
  print(json.dumps({'Parameters':[{'Name':'/x/'+k,'Value':v} for k,v in settings.items()]}))
 else: print('password')
if name=='docker':
 if args[:2]==['compose','version']: print('2.30.0')
 if args[:1]==['login']: sys.stdin.read()
 if os.getenv('MOCK_FAIL')=='health' and '--wait' in args and any(a==os.getenv('MOCK_SERVICE') or a.startswith(os.getenv('MOCK_SERVICE','backend')+'-') for a in args): sys.exit(1)
 if os.getenv('MOCK_FAIL')=='database' and '--wait' in args and 'mysql' in args: sys.exit(1)
 if os.getenv('MOCK_FAIL')=='readiness' and 'exec' in args and 'ai' in args and 'python' in args: sys.exit(1)
if name=='curl' and os.getenv('MOCK_FAIL')=='smoke': sys.exit(1)
'''
        for name in ['docker', 'aws', 'flock', 'curl']:
            path = bindir / name
            path.write_text(mock)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ['PATH'],
                        PROJECT_DIR=str(self.root), DRAIN_SECONDS='0',
                        MOCK_LOG=str(self.root / 'commands.log'))

    def deploy(self, service, fail='', revision='a'):
        self.env['MOCK_FAIL'] = fail
        self.env['MOCK_SERVICE'] = service
        image = '123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/' + service + ':' + revision * 40
        return subprocess.run(['bash', str(self.root / 'deploy/scripts/deploy.sh'), service, image],
                              env=self.env, text=True, capture_output=True)

    def bootstrap(self):
        for service in ['ai', 'backend', 'frontend']:
            result = self.deploy(service)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_independent_bootstrap_and_backend_switch(self):
        self.bootstrap()
        state = (self.root / '.deploy.env').read_text()
        self.assertIn('ACTIVE_FRONTEND_SLOT=blue', state)
        self.assertIn('ACTIVE_BACKEND_SLOT=blue', state)
        self.assertIn('AI_IMAGE=123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ai:' + 'a' * 40, state)
        result = self.deploy('backend', revision='b')
        self.assertEqual(result.returncode, 0, result.stderr)
        state = (self.root / '.deploy.env').read_text()
        self.assertIn('ACTIVE_FRONTEND_SLOT=blue', state)
        self.assertIn('ACTIVE_BACKEND_SLOT=green', state)
        self.assertIn('AI_IMAGE=123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ai:' + 'a' * 40, state)
        route = self.root / 'deploy/nginx/backend-upstream.conf'
        self.assertIn('backend-green:8080', route.read_text())
        self.assertIn('frontend-blue:8080', route.read_text())
        commands = (self.root / 'commands.log').read_text()
        self.assertEqual(commands.count('--path /meomuneum/v1/mysql '), 1)
        self.assertEqual(commands.count('--path /meomuneum/v1/postgres '), 1)
        self.assertIn('--no-recreate --wait', commands)
        self.assertNotIn('stop mysql', commands)
        self.assertIn('PROD_DB_URL=jdbc:mysql://mysql:3306/meomuneum', (self.root / '.runtime/backend-green.env').read_text())
        self.assertIn('PGUSER=ai', (self.root / '.runtime/ai.env').read_text())
        ai_env = (self.root / '.runtime/ai.env').read_text()
        self.assertIn('PGPASSWORD=pg$secret!:@/', ai_env)
        self.assertIn('DATABASE_URL=postgresql+psycopg://ai:pg%24secret%21%3A%40%2F@postgres:5432/ai', ai_env)
        result = self.deploy('ai', revision='b')
        self.assertEqual(result.returncode, 0, result.stderr)
        state = (self.root / '.deploy.env').read_text()
        self.assertIn('AI_IMAGE=123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ai:' + 'b' * 40, state)

    def test_health_failure_does_not_switch_backend(self):
        self.bootstrap()
        state = (self.root / '.deploy.env').read_text()
        self.assertNotEqual(self.deploy('backend', fail='health', revision='b').returncode, 0)
        self.assertEqual((self.root / '.deploy.env').read_text(), state)
        self.assertIn('backend-blue:8080', (self.root / 'deploy/nginx/backend-upstream.conf').read_text())

    def test_smoke_failure_restores_backend_route_and_state(self):
        self.bootstrap()
        state = (self.root / '.deploy.env').read_text()
        self.assertNotEqual(self.deploy('backend', fail='smoke', revision='b').returncode, 0)
        self.assertEqual((self.root / '.deploy.env').read_text(), state)
        self.assertIn('backend-blue:8080', (self.root / 'deploy/nginx/backend-upstream.conf').read_text())

    def test_database_failure_prevents_application_start(self):
        self.assertNotEqual(self.deploy('backend', fail='database').returncode, 0)
        self.assertFalse((self.root / '.deploy.env').exists())
        commands = (self.root / 'commands.log').read_text()
        self.assertNotIn('stop mysql', commands)
        self.assertNotIn('up -d --no-deps --wait', commands)

    def test_ai_readiness_failure_restores_previous_image_and_state(self):
        self.bootstrap()
        state = (self.root / '.deploy.env').read_text()
        result = self.deploy('ai', fail='readiness', revision='b')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / '.deploy.env').read_text(), state)
        commands = (self.root / 'commands.log').read_text()
        self.assertGreaterEqual(commands.count('up -d --no-deps --wait'), 2)

    def test_initial_health_failure_has_no_committed_state(self):
        self.assertNotEqual(self.deploy('ai', fail='health').returncode, 0)
        self.assertFalse((self.root / '.deploy.env').exists())
        self.assertIn('stop ai', (self.root / 'commands.log').read_text())


if __name__ == '__main__':
    unittest.main()
