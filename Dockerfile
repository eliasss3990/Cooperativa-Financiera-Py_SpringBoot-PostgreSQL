# Stage 1: Build
ARG JAVA_VERSION=17
FROM maven:3.9-eclipse-temurin-${JAVA_VERSION}-alpine AS build

WORKDIR /app

# Capa de dependencias (se cachea si pom.xml no cambia)
COPY pom.xml .
RUN mvn dependency:go-offline -B

# Compilar codigo fuente
COPY src ./src
RUN mvn clean package -DskipTests -B

# Stage 2: Runtime
FROM eclipse-temurin:${JAVA_VERSION}-jre-alpine AS runtime

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

COPY --from=build /app/target/app.jar app.jar

RUN mkdir -p /app/data && chown -R appuser:appgroup /app

USER appuser

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=5s --retries=5 --start-period=15s \
  CMD wget -q --spider http://localhost:8080/actuator/health || exit 1

ENTRYPOINT ["java", "-jar", "app.jar"]
