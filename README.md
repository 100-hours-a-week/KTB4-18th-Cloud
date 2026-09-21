# 머무는 음 V1 배포

> **단일 EC2 + Docker Compose 기반의 초기 배포 환경을 구성하고, FE·BE는 Blue/Green, AI는 단일 교체 방식으로 배포하도록 설계했습니다.**

## 1. 프로젝트 개요

머무는 음 V1은 초기 서비스 단계에서 운영 복잡도와 비용을 낮추기 위해 **하나의 EC2에서 여러 컨테이너를 운영**합니다.

배포 구성은 서비스 소스 저장소와 분리하여 Cloud 저장소에서 관리합니다.

| 구분 | 구성 |
| --- | --- |
| Frontend | React 19 + Vite 8 |
| Backend | Java 25 + Spring Boot 4.1.1 |
| AI | Python 3.12 + FastAPI |
| Database | MySQL 8.4, PostgreSQL 17 + pgvector |
| Runtime | Docker Compose |
| Registry | Amazon ECR |
| CD | GitHub Actions + AWS SSM |
| Reverse Proxy | Nginx |

---

## 2. 배포 아키텍처

```text
Client
  ↓
Nginx :80
  ├─ /api/* → Backend
  └─ /*      → Frontend

EC2
├─ Nginx
├─ Frontend Blue / Green
├─ Backend Blue / Green
├─ AI
├─ MySQL
└─ PostgreSQL + pgvector
```

- FE 정적 파일은 Nginx로 제공
- `/api/*` 요청은 Backend로 전달
- Backend는 MySQL 사용
- AI는 PostgreSQL + pgvector 사용
- DB는 Docker Volume으로 데이터를 유지
- BE·AI·DB 포트는 외부에 직접 공개하지 않음

---

## 3. 배포 전략

### Frontend / Backend — Blue/Green

신규 버전을 기존 서비스와 동시에 실행한 뒤 Health Check와 Smoke Test를 통과한 경우에만 트래픽을 전환합니다.

```text
현재 Blue 서비스 중
        ↓
Green 신규 배포
        ↓
Health Check
        ↓
Smoke Test
        ↓
Nginx Traffic 전환
        ↓
기존 Blue 종료
```

배포 실패 시 기존 슬롯으로 다시 전환하여 서비스 중단 위험을 줄입니다.

### AI — 단일 컨테이너 교체

AI는 초기 단계의 자원 사용량을 고려해 Blue/Green 대신 단일 컨테이너로 운영합니다.

```text
기존 AI
  ↓
신규 Image Pull
  ↓
Container 교체
  ↓
/readiness 확인
```

교체 중 짧은 중단이 발생할 수 있으며, 실패하면 이전 Image SHA로 다시 실행합니다.

---

## 4. Health Check 기준

| 서비스 | 확인 Endpoint | 기준 |
| --- | --- | --- |
| Backend | `/actuator/health` | Spring Application 정상 상태 |
| AI | `/health` | Process 생존 여부 |
| AI | `/readiness` | PostgreSQL 연결 및 필수 테이블 준비 |

단순히 Container가 실행 중인지가 아니라 **실제로 요청을 받을 수 있는 상태인지 확인한 뒤 배포를 완료**합니다.

---

## 5. CI/CD 흐름

```text
Source 변경
   ↓
GitHub Actions
   ↓
Test / Build
   ↓
Docker Image Build
   ↓
Trivy 취약점 검사
   ↓
ECR Push
   ↓
AWS SSM
   ↓
EC2 배포
   ↓
Health / Smoke Check
   ↓
Traffic 전환
```

### Image Version

배포 이미지는 `latest` 대신 **소스 Commit SHA**를 사용합니다.

```text
mme-backend:<commit-sha>
mme-frontend:<commit-sha>
mme-ai:<commit-sha>
```

이를 통해 어떤 소스가 운영에 배포됐는지 추적하고 이전 버전으로 되돌릴 수 있도록 했습니다.

---

## 6. SSH 대신 SSM을 사용한 이유

배포를 위해 EC2의 22번 포트를 외부에 공개하지 않고 **AWS Systems Manager Run Command**를 사용합니다.

```text
GitHub Actions
   ↓ OIDC
AWS IAM Role
   ↓
SSM Run Command
   ↓
EC2
```

- 장기 AWS Access Key 대신 GitHub OIDC 사용
- EC2 SSH 공개 불필요
- ECR Pull 및 필요한 Parameter Store 경로만 IAM 권한 부여
- 배포 명령을 AWS 관리 경로로 전달

---

## 7. 환경변수와 Secret 관리

Application Secret은 Git 저장소에 저장하지 않고 **AWS Systems Manager Parameter Store**에서 가져옵니다.

```text
SSM Parameter Store
        ↓
EC2 배포 시 조회
        ↓
.runtime/*.env
        ↓
Docker Compose
```

Runtime 환경 파일은 Git에 포함하지 않으며 파일 권한을 제한합니다.

DB 계정은 Application용 일반 계정을 사용하고, AI Container에 PostgreSQL 관리자 비밀번호를 전달하지 않습니다.

SSM Parameter Store에는 최소한 다음 키를 등록합니다.

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

IAM은 AWS Console에서 관리하며 다음 세 역할로 분리합니다.

- GitHub Build Role: ECR Push
- GitHub Deploy Role: 지정 EC2에 SSM Run Command 실행
- EC2 Role: ECR Pull, 지정 SSM Parameter 조회, 필요한 KMS 복호화

실제 비밀번호·API Key·AWS Key·PEM 파일은 Git에 저장하지 않습니다.

---

## 8. 저장소 구조

```text
.github/workflows/  GitHub Actions CI/CD
docker/             FE·BE·AI 이미지 빌드 정의
deploy/nginx/       외부 Reverse Proxy와 활성 슬롯 설정
deploy/postgres/    PostgreSQL 최초 pgvector·계정 초기화
deploy/scripts/     SSM·환경변수·배포·롤백 실행 코드
tests/              배포 상태 전이와 입력 검증 테스트
compose.yml         단일 EC2의 전체 Container 구성
```

IAM 정책은 AWS Console에서, 실제 Secret은 SSM Parameter Store에서 관리하므로 별도 `aws/`, `config/` 폴더를 두지 않습니다.

---

## 9. DB 운영 원칙

Application 배포와 Database Lifecycle을 분리했습니다.

```text
App 배포
→ Container 교체 가능

DB
→ Volume 유지
→ App Rollback 시 중지하지 않음
```

`docker compose down -v`처럼 Volume을 제거하는 명령은 운영 배포에 사용하지 않습니다.

Docker Volume은 Container 교체에는 대응하지만 EC2/EBS 장애까지 보호하지 않으므로 별도 Backup이 필요합니다.

---

## 10. 배포 실패 처리

### FE / BE

```text
신규 Slot 배포
↓
Health Check 실패
→ 기존 Slot 유지

Traffic 전환
↓
Smoke Test 실패
→ 기존 Nginx Route 복구
→ 신규 Slot 중지
```

### AI

```text
신규 AI 교체
↓
Readiness 실패
→ 이전 Image SHA 재실행
```

DB Migration과 데이터 변경은 Application Rollback 대상에 포함하지 않습니다.

---

## 11. 현재 검증 결과

| 항목 | 결과 |
| --- | --- |
| FE Docker Image Build | ✅ 성공 |
| BE Docker Image Build | ✅ 성공 |
| MySQL Container | ✅ 정상 |
| PostgreSQL + pgvector | ✅ 정상 |
| Nginx → FE | ✅ HTTP 200 |
| Nginx → BE | ✅ `/actuator/health` UP |
| AI PostgreSQL 일반 계정 | ✅ 권한 분리 확인 |
| pgvector 저장·검색 | ✅ 검증 |
| 배포/복구 자동 테스트 | ✅ 10개 구성 |
| AI 전체 구동 | ⚠️ Source 상태로 인해 미검증 |
| ECR Push / SSM 실제 배포 | ⚠️ 아직 미실행 |
| EC2 x86_64 운영 배포 | ⚠️ 아직 미검증 |

> 로컬 검증은 실제 AWS 운영 환경의 통합 테스트를 대체하지 않습니다.

---

## 12. 현재 구조의 Trade-off

V1은 빠른 MVP 배포와 운영 단순화를 우선한 구조입니다.

| 선택 | 장점 | 한계 |
| --- | --- | --- |
| 단일 EC2 | 비용·운영 복잡도 낮음 | EC2가 단일 장애점 |
| Docker Compose | 서비스 실행 구조 단순 | 다중 서버 확장 관리에는 한계 |
| FE/BE Blue/Green | 배포 중단 최소화 | 일시적으로 신·구 Container 동시 실행 |
| AI 단일 교체 | 자원 사용 절감 | 배포 중 짧은 중단 가능 |
| DB Container 운영 | 초기 구축 단순 | 운영 DB HA·Backup 별도 필요 |
| SSM 배포 | SSH 공개 불필요 | AWS IAM·SSM 설정 필요 |

---

## 13. 향후 개선

V1 운영 및 부하테스트 결과를 기준으로 다음 단계를 검토합니다.

```text
단일 EC2
↓
Application / DB 분리
↓
ALB + Auto Scaling
↓
서비스별 독립 확장
↓
필요 시 Container Orchestration 도입
```

초기부터 복잡한 구조를 도입하기보다 **현재 서비스 규모에서 필요한 수준으로 시작하고, 병목과 운영 요구가 확인될 때 단계적으로 확장하는 것**을 기준으로 설계했습니다.
