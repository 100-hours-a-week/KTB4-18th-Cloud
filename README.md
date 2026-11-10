# KTB4-18th-Cloud

머문음(meomuneum) v3의 Kubernetes 배포 정의입니다. EKS 클러스터 `meomuneum-v3`의 Argo CD가 이 레포의 `main`을 읽어 배포합니다.

| 경로 | 내용 |
|---|---|
| `k8s/v3-app/` | Argo CD가 동기화하는 앱 매니페스트 (frontend, core, chat, ai, hazelcast) |
| `k8s/v3-app-init/` | 최초 1회 실행한 DB·채팅 초기화 Job. |
| `argocd/` | Argo CD Application 정의 |


