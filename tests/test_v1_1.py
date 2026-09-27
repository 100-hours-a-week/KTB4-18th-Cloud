"""v1.1에서 변경된 이미지 태그 계약과 배포 스크립트 연결만 검증합니다."""
import importlib.util
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    'ssm_command_v1_1', ROOT / 'deploy/scripts/ssm-command-v1.1.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class V11DeploymentContract(unittest.TestCase):
    def setUp(self):
        self.repository = (
            '764788758503.dkr.ecr.ap-northeast-2.amazonaws.com/mme-backend')
        self.env = {
            'INSTANCE_ID': 'i-08d8c71afdc921985',
            'GITHUB_REPOSITORY': '100-hours-a-week/KTB4-18th-Cloud',
            'GITHUB_SHA': 'a' * 40,
            'SERVICE': 'backend',
            'IMAGE': self.repository + ':' + 'b' * 40 + '-' + 'c' * 12,
        }

    def test_composite_tag_calls_v1_1_deployer(self):
        value = module.command(self.env)
        script = value['Parameters']['commands'][0]
        self.assertIn('bash deploy/scripts/deploy-v1.1.sh backend ', script)
        self.assertEqual(
            subprocess.run(['bash', '-n'], input=script, text=True).returncode, 0)

    def test_accepts_digest(self):
        image = self.repository + '@sha256:' + 'd' * 64
        self.assertEqual(
            module.command(dict(self.env, IMAGE=image))['InstanceIds'],
            ['i-08d8c71afdc921985'])

    def test_rejects_old_or_malformed_tags(self):
        for tag in ['b' * 40, 'b' * 40 + '-' + 'c' * 11, 'latest']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                module.command(dict(self.env, IMAGE=self.repository + ':' + tag))

    def test_deploy_script_rejects_old_tag_before_deployment(self):
        image = self.repository + ':' + 'b' * 40
        result = subprocess.run(
            ['bash', str(ROOT / 'deploy/scripts/deploy-v1.1.sh'), 'backend', image],
            text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('source-cloud commit tag or digest', result.stderr)


if __name__ == '__main__':
    unittest.main()
