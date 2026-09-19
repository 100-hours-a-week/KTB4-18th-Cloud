# 머무는 음 V1 배포

이 폴더는 소스 레포와 별도로 관리하는 배포 구성이다. [KTB4-18th-Cloud](https://github.com/100-hours-a-week/KTB4-18th-Cloud)에 이 폴더를 올리면 `.github/workflows`를 사용할 수 있다. 현재 폴더는 Git 저장소가 아니다.

## 확인한 소스 (2026-09-19)

| 레포 | 확인 commit | 실제 구성 |
| --- | --- | --- |
| [FE](https://github.com/100-hours-a-week/KTB4-18th-FE) | b0f08fc930b47cad38d8fe9e811d23770437e276 | React 19, Vite 8, npm lockfile, `npm run lint/build` |
| [BE](https://github.com/100-hours-a-week/KTB4-18th-BE) | 87cd235b867a0adba870b3066bd92c1e12589638 | Java 25, Spring Boot 4.1.1, Gradle, MySQL, Actuator |
| [AI](https://github.com/100-hours-a-week/KTB4-18th-AI) | d422e471075b5c278a650018c3638a4cc64f44b1 | Python >=3.12.13, uv.lock, FastAPI/uvicorn 의존성만 존재 |

**AI에는 아직 Python 실행 코드와 health endpoint가 없다.** AI 레포에 ASGI 앱과 `/health`를 구현하고 실제 `module:object`를 CI의 `ai_app_module`로 지정해야 통합 CI/CD가 성공한다. Dockerfile은 존재하지 않는 앱을 실행 가능한 것처럼 통과시키지 않고 import 검사에서 실패한다. AI health 경로를 바꾸면 SSM의 `AI_HEALTH_PATH`와 배포 프로세스의 `AI_HEALTH_PATH`를 함께 맞춘다.

BE는 `/health`가 아닌 `/actuator/health`를 사용한다. 소스의 Spring Security 변경 시 해당 endpoint에 대한 내부 무인증 health 요청을 허용해야 한다. 현재 BE에 AI 호출 코드는 없다. Compose의 `AI_BASE_URL`은 향후 BE에서 읽도록 구현해야 할 환경변수 계약이다.

## 구조

- FE 정적 빌드 결과를 Nginx 8080에서 제공한다. SPA history fallback을 포함한다.
- 외부 요청은 Compose의 Nginx 80번 포트로 들어간다. `/api/`는 경로를 보존하여 BE로, 나머지는 FE로 보낸다.
- FE/BE/AI를 blue와 green 두 묶음으로 배포한다. 새 슬롯의 세 컨테이너가 healthy가 된 다음 proxy 설정을 reload한다.
- 각 BE는 같은 색 AI 주소를 사용한다. `ai-router:8000`은 별도 내부 소비자용 active AI 주소다.
- EC2 한 대의 같은 Compose에 Nginx, FE, BE, AI, MySQL 8.4, PostgreSQL 17 + pgvector를 함께 실행한다. BE/AI/DB 포트는 호스트에 공개하지 않는다.
- BE는 `mysql:3306`, AI는 `postgres:5432`에 연결한다. DB는 `mysql-data`, `postgres-data` 영구 볼륨을 사용하며 Blue/Green 슬롯이 공유한다.
- PostgreSQL 최초 초기화 시 `vector` 확장을 활성화하고 AI 전용 일반 로그인 역할을 생성한다. AI에 PostgreSQL 관리자 비밀번호를 전달하지 않는다.
- 앱 배포는 DB를 `--no-recreate`로 시작/상태 확인만 한다. 앱 실패 복구나 슬롯 종료 시 DB는 중지하지 않는다. DB 버전 업그레이드와 비밀번호 변경은 별도 유지보수로 수행한다.
- AI router와 외부 Nginx의 reload는 순차적이므로 완전히 원자적인 전환은 아니다. 서로 호환되는 API 변경과 DB migration을 전제로 한다.
- 전환 후 proxy를 통한 smoke test가 실패하면 기존 설정을 reload하고 신규 슬롯을 중지한다. 복구 reload까지 실패하면 양쪽 슬롯을 유지한다.
- 성공하면 `.deploy.env`에 이미지와 active 색상을 저장하고 30초 후 기존 슬롯을 중지한다. 장시간 요청이 있으면 `DRAIN_SECONDS`를 늘린다. DB migration/data는 자동 rollback하지 않는다.

기존 호스트 Nginx와 Compose Nginx를 혼용하던 구성을 **Compose Nginx**로 통일했다. 기존 호스트 Nginx가 80번을 점유하면 먼저 별도 전환 작업이 필요하다. HTTPS는 이 구성에 포함되지 않는다. 443 포트만 열어 TLS가 되는 것처럼 구성하지 않았다. 운영 공개 전 인증서가 있는 TLS 종료 계층을 설정해야 하며 프록시 신뢰/forwarded 헤더도 그 구조에 맞춘다.

## 서버 준비

Linux EC2에 Docker Engine, Compose **2.30.0 이상**, AWS CLI, Python 3, curl, util-linux(flock)가 필요하다. 서버 CPU는 CI 기본 빌드와 같은 x86_64를 전제로 한다. SSM Agent가 실행되고 AWS Systems Manager에 Online 상태로 등록되어야 한다. CD는 AWS-RunShellScript를 통해 root 권한으로 `/opt/meomuneum`에 설치한다. SSH 키나 22번 공개는 필요하지 않다. blue/green 두 묶음을 동시에 실행할 메모리를 확보한다.

서버 IAM Role에는 ECR pull, `/meomuneum/v1/backend/*`, `/meomuneum/v1/ai/*`, `/meomuneum/v1/mysql/*`, `/meomuneum/v1/postgres/*`의 `ssm:GetParametersByPath`, 필요한 KMS 복호화 권한을 부여한다. 각 SSM 파라미터 마지막 이름이 환경변수 이름이 된다.

DB 초기화 파라미터 (비밀번호는 SecureString):

```text
/meomuneum/v1/mysql/MYSQL_DATABASE
/meomuneum/v1/mysql/MYSQL_USER
/meomuneum/v1/mysql/MYSQL_PASSWORD
/meomuneum/v1/mysql/MYSQL_ROOT_PASSWORD
/meomuneum/v1/postgres/POSTGRES_DB
/meomuneum/v1/postgres/POSTGRES_USER
/meomuneum/v1/postgres/POSTGRES_PASSWORD
/meomuneum/v1/postgres/POSTGRES_APP_USER
/meomuneum/v1/postgres/POSTGRES_APP_PASSWORD
```

`config/mysql.env.example`, `config/postgres.env.example`에 이름 예시가 있다. DB 파일이 없는 최초 배포에서만 SSM으로부터 저장하며, 이후 앱 배포에서는 기존 DB 자격 증명을 유지한다. 이미 볼륨이 존재하는 DB는 환경변수를 바꿔도 DB 내부 비밀번호가 자동 변경되지 않는다. 비밀번호 회전은 DB 내부 계정과 런타임 파일을 함께 변경하는 유지보수로 진행한다.

BE의 `PROD_DB_URL`, `PROD_DB_USERNAME`, `PROD_DB_PASSWORD`는 MySQL 설정으로부터 자동 생성하여 SSM의 같은 키보다 우선 적용한다. `/meomuneum/v1/backend/LOGGING_LEVEL_ROOT=INFO` 등 BE 앱 설정을 최소 하나 등록한다. AI에는 동일한 방식으로 `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`를 주입한다. 현재 AI 소스에는 DB 드라이버와 연결 코드도 없으므로 이 값을 읽는 DB 연결 구현이 필요하다.
AI는 원본 `.env.example`의 `APP_ENV`, `AI_PROVIDER`, `OPENAI_API_KEY`, `OPENAI_MODEL`, `OPENAI_TIMEOUT_SECONDS`, `LASTFM_API_KEY`를 `/meomuneum/v1/ai/` 아래에 등록한다. 실제 앱이 요구하는 값을 설정한다.

SSM 값은 `.runtime/<service>-<slot>.env`에 권한 600으로 기록된다. Compose raw 형식으로 `$`, `#`, 따옴표와 역슬래시를 보존한다. 여러 줄 값은 거부하므로 별도 파일 secret으로 설계해야 한다. `.runtime`, `.state`, `.deploy.env`는 Git에 올리지 않는다. 서버 재부팅 후 컨테이너가 재시작할 수 있도록 env 파일은 `/run` 대신 보호된 프로젝트 디렉터리에 유지한다.

최초 배포는 `.deploy.env`가 없거나 비어 있는 상태에서 자동으로 blue로 시작한다. `.deploy.env.example`은 구성 검사 전용이며 운영 상태로 복사하지 않는다.

```bash
# 전체 폴더를 /opt/meomuneum에 설치한 후 실행
cd /opt/meomuneum
bash scripts/deploy.sh \
  123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/mme-frontend:<40자리-SHA> \
  123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/mme-backend:<40자리-SHA> \
  123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/mme-ai:<40자리-SHA>
```

이미지는 40자리 소스 commit SHA 또는 `@sha256:<64자리>`만 받는다. ECR 저장소는 태그 불변(immutable)을 설정한다. 같은 commit을 재빌드해야 하면 새 태그를 덮어쓰지 말고 별도 정책으로 처리한다.

## GitHub Actions

인프라 레포의 Variables:

- `MME_FRONTEND_ECR_URI`, `MME_BACKEND_ECR_URI`, `MME_AI_ECR_URI`: 태그 없는 ECR 저장소 URI.
- `MME_EC2_INSTANCE_ID`: SSM으로 배포할 인스턴스 ID.

Secrets (CD 항목은 production Environment에 설정 가능):

- `MME_AWS_BUILD_ROLE_ARN`: GitHub OIDC로 assume할 ECR push role. 이 인프라 레포의 신뢰할 수 있는 ref로 trust policy를 제한한다.
- `MME_AWS_DEPLOY_ROLE_ARN`: `production` Environment에서만 사용하는 SSM 배포 Role.

`aws/`의 IAM 정책 초안은 확인된 AWS 계정 `764788758503`, 서울 리전, Cloud 레포, 인스턴스 `i-08d8c71afdc921985`로 제한되어 있다. 다른 대상으로 변경할 때 정책과 `scripts/ssm-command.py`의 검증을 함께 수정한다. 아직 실제 IAM 적용 여부는 AWS에서 확인해야 한다.

`MME V1 CI`는 PR/main push에서 배포 파일 검사를 실행한다. 수동 실행하면 선택한 세 소스 ref를 checkout하고 FE lint/build, MySQL 8.4를 사용하는 BE 테스트, AI import/pytest 검증 후 이미지를 ECR에 게시한다. build 전까지 AWS 자격 증명을 주입하지 않는다. `deploy=true`일 때 세 이미지 검증·게시가 모두 성공한 뒤 CD를 호출한다. 소스 레포의 push가 인프라 CI를 자동으로 실행하지는 않는다. 필요하면 소스 레포 측 dispatch 연동을 별도로 추가한다.

`MME V1 CD` 수동 실행은 이미 CI로 검증한 세 이미지 URI를 받는다. main 브랜치에서만 실행한다. OIDC 인증 후 지정 EC2로 SSM Run Command를 보내며, EC2는 공개 Cloud 레포의 정확한 인프라 commit SHA 아카이브를 내려받는다. 따라서 레포를 비공개로 전환하면 아티팩트 전송 경로를 변경해야 한다. production Environment의 배포 허용 브랜치를 main으로 제한한다. 최초 실행에서만 proxy 설정을 설치하며 운영 active route를 덮어쓰지 않는다. `nginx/default.conf` 자체를 변경할 때는 서버에서 백업 후 갱신하고 `nginx -t`/reload하는 별도 설정 배포가 필요하다. 같은 서버에 실행되는 배포는 flock으로 잠근다.

GitHub production Environment 보호 규칙과 허용 branch를 팀 정책에 맞게 설정한다. 실제 AWS 리소스 생성, GitHub secret 등록, push, 운영 배포는 이 로컬 수정에 포함되지 않는다.

## 검증

```bash
bash -n scripts/deploy.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
mkdir -p .runtime
touch .runtime/{backend,ai}-{blue,green}.env .runtime/mysql.env .runtime/postgres.env
docker compose --env-file .deploy.env.example --profile blue --profile green config --quiet
```

테스트는 외부 명령을 대역으로 바꿔 최초 배포, 연속 전환, health 실패, smoke 실패의 상태/route 복구와 secret 문자 보존을 확인한다. 실제 컨테이너, AWS, SSH의 통합 검증을 대체하지 않는다.

Dockerfile의 build context는 각각 원본 소스 레포 루트다. CI가 이 폴더의 `.dockerignore`를 소스 context로 복사한다. 로컬 빌드에서도 동일하게 복사해야 한다.

## 단일 EC2 DB 운영

`docker compose down -v`는 DB 볼륨까지 삭제하므로 운영 배포에 사용하지 않는다. 영구 볼륨은 컨테이너 교체를 견디지만 EC2/EBS 장애를 대비한 백업을 대신하지 않는다. MySQL dump와 PostgreSQL dump 또는 EBS 백업을 별도로 보관한다.

`postgres/init/01-vector.sh`는 빈 데이터 볼륨에서만 실행된다. 기존 PostgreSQL 볼륨을 가져오는 경우 `vector` 확장과 AI 역할을 별도 migration으로 준비해야 한다. 벡터 차원/테이블/인덱스는 AI 모델이 정해진 뒤 AI migration에서 관리한다. [pgvector 공식 문서](https://github.com/pgvector/pgvector)를 기준으로 확장을 활성화한다.

## 로컬 Docker 검증 결과 (2026-09-19)

- macOS ARM64 / Docker Engine 29.6.1에서 원본 FE·BE 소스로 이미지 빌드 성공.
- 별도 `mumeun-runtime-check` Compose 프로젝트에서 MySQL, PostgreSQL+pgvector, FE, BE, Nginx 모두 healthy.
- Nginx 경유 FE `/`와 SPA 하위 경로 HTTP 200, BE `/actuator/health`는 `status: UP`.
- AI 일반 계정이 superuser가 아님을 확인하고, pgvector 0.8.6의 벡터 저장·거리순 검색을 검증한 뒤 테스트 SQL을 rollback.
- AI 의존성 설치는 성공했지만 upstream에 `main` 모듈이 없어 이미지의 앱 import 검증은 실패. AI 전체 구동과 AI→DB 연동은 아직 검증할 수 없음.
- 배포/복구/DB 시작 실패/secret 보존 자동 테스트 7개, ShellCheck, Actionlint 통과.
- 이미지 게시, SSM 배포 명령 실행, GitHub Actions 원격 실행, EC2 x86_64 환경 배포는 미실행.
