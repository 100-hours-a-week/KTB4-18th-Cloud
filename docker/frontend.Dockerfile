# syntax=docker/dockerfile:1
# Cloud 저장소에서 FE 소스를 이미지로 만드는 전용 Dockerfile입니다.
# build stage: Node로 정적 파일을 생성합니다.
FROM node:24-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
# npm 캐시는 BuildKit 캐시 마운트로 재사용합니다.
RUN --mount=type=cache,target=/root/.npm npm ci
COPY . .
RUN npm run build

# runtime stage: 보안 패치가 적용된 Alpine 기반 non-root Nginx로 정적 파일만 제공합니다.
# digest를 고정하여 CI와 운영 환경에서 동일한 기반 이미지를 사용합니다.
FROM nginxinc/nginx-unprivileged:1.31.3-alpine3.24@sha256:f972e5322b9797dc2a6b830030094426437b1ae7032e4644496395336ac6fdac
COPY --from=build /app/dist /usr/share/nginx/html
RUN printf 'server { listen 8080; root /usr/share/nginx/html; location = /health { return 200 "ok"; } location / { try_files $uri $uri/ /index.html; } }\n' > /etc/nginx/conf.d/default.conf
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/health || exit 1
