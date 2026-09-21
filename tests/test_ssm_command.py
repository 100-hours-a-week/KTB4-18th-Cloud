"""CD가 신뢰한 입력만 받아 안전한 SSM 명령을 만드는지 검사합니다."""
import importlib.util
from pathlib import Path
import subprocess
import unittest

spec = importlib.util.spec_from_file_location(
    'ssm_command', Path(__file__).resolve().parents[1] / 'deploy/scripts/ssm-command.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SSMCommand(unittest.TestCase):
    def setUp(self):
        self.env = {'INSTANCE_ID': 'i-08d8c71afdc921985',
                    'GITHUB_REPOSITORY': '100-hours-a-week/KTB4-18th-Cloud',
                    'GITHUB_SHA': 'a' * 40,
                    'SERVICE': 'backend',
                    'IMAGE': ('764788758503.dkr.ecr.ap-northeast-2.amazonaws.com/mme-backend:'
                              + 'b' * 40)}

    def test_pinned_release_and_bash_syntax(self):
        value = module.command(self.env)
        self.assertEqual(value['InstanceIds'], ['i-08d8c71afdc921985'])
        script = value['Parameters']['commands'][0]
        self.assertIn('/archive/' + 'a' * 40 + '.tar.gz', script)
        self.assertIn('bash deploy/scripts/deploy.sh backend ', script)
        self.assertEqual(subprocess.run(['bash', '-n'], input=script, text=True).returncode, 0)
        self.assertNotIn('stop mysql', script)

    def test_reject_untrusted_input(self):
        for key, value in [('INSTANCE_ID', 'i-foo; id'), ('GITHUB_SHA', 'main'),
                           ('GITHUB_REPOSITORY', 'other/repo'), ('SERVICE', 'database'),
                           ('IMAGE', 'other.example/app:latest')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                module.command(dict(self.env, **{key: value}))


if __name__ == '__main__':
    unittest.main()
