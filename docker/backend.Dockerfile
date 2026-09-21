# syntax=docker/dockerfile:1
# Cloud 저장소에서 BE 소스를 이미지로 만드는 전용 Dockerfile입니다.
# build stage: Gradle로 실행 가능한 Spring Boot JAR를 생성합니다.
FROM eclipse-temurin:25-jdk AS build
WORKDIR /app
# 의존성 파일을 소스보다 먼저 복사하고 Gradle 캐시를 재사용합니다.
COPY gradle ./gradle
COPY gradlew build.gradle settings.gradle ./
RUN chmod +x gradlew
RUN --mount=type=cache,target=/root/.gradle ./gradlew dependencies --no-daemon
COPY src ./src
# CI에서 ./gradlew test를 먼저 통과하므로 이미지 빌드에서는 테스트를 중복 실행하지 않습니다.
RUN --mount=type=cache,target=/root/.gradle ./gradlew bootJar -x test --no-daemon && \
    find build/libs -name '*.jar' ! -name '*-plain.jar' -exec cp {} /app/app.jar \;
# runtime stage: JDK와 소스 없이 JRE와 app.jar만 포함합니다.
FROM eclipse-temurin:25-jre
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build --chown=10001:10001 /app/app.jar ./app.jar
# 최소 권한 사용자로 실행합니다.
USER 10001:10001
EXPOSE 8080
# 운영 환경에서 JVM heap과 timezone 옵션을 JAVA_OPTS로 주입할 수 있습니다.
ENV JAVA_OPTS=""
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=6 \
  CMD curl -fsS http://127.0.0.1:8080/actuator/health || exit 1
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar app.jar"]
