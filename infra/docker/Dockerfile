# 빌드 컨텍스트 = 리포지토리의 back/ 디렉터리
# 예: docker build -f infra/docker/Dockerfile ./back
# syntax=docker/dockerfile:1

# ---- build ----------------------------------------------------------------
FROM eclipse-temurin:25-jdk AS build
WORKDIR /app

# 의존성 레이어 캐시 (소스보다 먼저)
COPY gradlew build.gradle settings.gradle lombok.config ./
COPY gradle ./gradle
RUN chmod +x gradlew && (./gradlew --no-daemon -q dependencies || true)

COPY config ./config
COPY src ./src

# 테스트/검증은 CI(backend-ci.yml)에서 이미 돌았으므로 여기선 제외.
# bootJar 산출물만 취함(-plain.jar 은 제외).
RUN ./gradlew --no-daemon clean bootJar -x test -x check \
 && for jar in build/libs/*.jar; do \
        case "$jar" in *-plain.jar) continue ;; esac; \
        cp "$jar" app.jar; \
        break; \
    done

# ---- runtime -------------------------------------------------------------
FROM eclipse-temurin:25-jre AS runtime

# ffmpeg = DailyLog 컴필레이션 인코딩. curl = 헬스체크.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg curl tzdata \
 && rm -rf /var/lib/apt/lists/*

ENV TZ=Asia/Seoul
RUN useradd -r -u 1001 -m gommit
WORKDIR /app

COPY --from=build --chown=gommit:gommit /app/app.jar ./app.jar

# media-tmp named volume 이 root 소유로 초기화돼 비루트 런타임이 쓰기 실패하는 것 방지
RUN mkdir -p /app/media-tmp && chown -R gommit:gommit /app/media-tmp

USER gommit
EXPOSE 8080

# compose 의 JAVA_OPTS 가 덮어씀. 없으면 컨테이너 비율 기반.
ENV JAVA_OPTS="-XX:MaxRAMPercentage=70 -XX:+ExitOnOutOfMemoryError -Duser.timezone=Asia/Seoul"
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar app.jar"]

HEALTHCHECK --interval=30s --timeout=3s --start-period=90s --retries=5 \
  CMD curl -fsS http://localhost:8080/actuator/health || exit 1
