# Stage 1: Build
FROM eclipse-temurin:${JAVA_VERSION:-17}-jdk-alpine AS build

WORKDIR /app

# Capa de dependencias (se cachea si pom.xml no cambia)
COPY pom.xml .
RUN mvn dependency:go-offline -B

# Copiar y construir codigo fuente
COPY src ./src
RUN mvn clean package -DskipTests -B

# Stage 2: Runtime
FROM eclipse-temurin:${JAVA_VERSION:-17}-jre-alpine AS runtime

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

COPY --from=build /app/target/app.jar app.jar

RUN mkdir -p /app/data && chown -R appuser:appgroup /app

USER appuser

EXPOSE ${APP_PORT:-8080}

HEALTHCHECK --interval=10s --timeout=5s --retries=5 --start-period=15s \
  CMD wget -q --spider http://localhost:${APP_PORT:-8080}/actuator/health || exit 1

ENTRYPOINT ["java", "-jar", "app.jar"]
