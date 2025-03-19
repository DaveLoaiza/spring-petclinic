# syntax=docker/dockerfile:1

# Create a stage for resolving and downloading dependencies.
FROM eclipse-temurin:21-jdk-jammy as deps

WORKDIR /build

# Copy the mvnw wrapper with executable permissions.
COPY --chmod=0755 mvnw mvnw
COPY .mvn/ .mvn/

# Download dependencies as a separate step to take advantage of Docker's caching.
RUN --mount=type=bind,source=pom.xml,target=pom.xml \
    --mount=type=cache,target=/root/.m2 ./mvnw dependency:go-offline -DskipTests

# Create a stage for building the application based on the stage with downloaded dependencies.
FROM deps as package

WORKDIR /build

COPY ./src src/
RUN --mount=type=bind,source=pom.xml,target=pom.xml \
    --mount=type=cache,target=/root/.m2 \
    ./mvnw package -DskipTests && \
    mv target/$(./mvnw help:evaluate -Dexpression=project.artifactId -q -DforceStdout)-$(./mvnw help:evaluate -Dexpression=project.version -q -DforceStdout).jar target/app.jar

# Create a stage for extracting the application into separate layers.
FROM package as extract

WORKDIR /build

RUN java -Djarmode=layertools -jar target/app.jar extract --destination target/extracted

# Final stage with Lightrun agent
FROM eclipse-temurin:21-jre-jammy AS final

# Install Lightrun agent
WORKDIR /opt/lightrun
ENV LIGHTRUN_KEY=<INSERT_LIGHTRUN_KEY>
RUN apt-get update && apt-get install -y curl && apt-get install -y unzip
RUN bash -c "$(curl -L 'https://app.lightrun.com/public/download/company/<INSERT_LIGHTRUN_COMPANYID>/install-agent.sh?platform=linux')"

# Create a non-privileged user for the app
ARG UID=10001
RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "/nonexistent" \
    --shell "/sbin/nologin" \
    --no-create-home \
    --uid "${UID}" \
    appuser

# Copy the application layers
WORKDIR /app
COPY --from=extract build/target/extracted/dependencies/ ./
COPY --from=extract build/target/extracted/spring-boot-loader/ ./
COPY --from=extract build/target/extracted/snapshot-dependencies/ ./
COPY --from=extract build/target/extracted/application/ ./

# Make sure appuser can access the Lightrun agent directory
RUN chown -R appuser:appuser /opt/lightrun

# Switch to non-root user
USER appuser

EXPOSE 8080

# Start the application with the Lightrun agent
ENTRYPOINT ["java", "-agentpath:/opt/lightrun/agent/lightrun_agent.so", "org.springframework.boot.loader.launch.JarLauncher"]