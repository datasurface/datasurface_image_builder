# syntax=docker/dockerfile:1.7

ARG BASE_IMAGE=python:3.12
ARG MAVEN_IMAGE=maven:3.9-eclipse-temurin-25

FROM scratch AS local-wheels
COPY wheelhouse/ /wheelhouse/

FROM scratch AS local-java-artifacts
COPY java-artifacts/ /java-artifacts/

# Resolve Java dependencies during the customer build. The private GitLab Maven
# repository supplies only thin com.datasurface jars; every other jar comes from
# the configured customer/public Maven mirror.
FROM --platform=$BUILDPLATFORM ${MAVEN_IMAGE} AS java-dependencies

ARG DATASURFACE_VERSION
ARG GITLAB_PROJECT_ID=77796931
ARG JAVA_DEPENDENCY_PROFILES=postgresql,sqlserver,snowflake,trino,aws,azure
ARG MAVEN_REPOSITORY_URL=https://repo1.maven.org/maven2

ENV MAVEN_REPOSITORY_URL=${MAVEN_REPOSITORY_URL}

COPY java-dependencies/pom.xml java-dependencies/settings.xml /build/

RUN --mount=type=bind,from=local-java-artifacts,source=/java-artifacts,target=/tmp/local-java-artifacts,ro \
    --mount=type=secret,id=gitlab_package_token,required=false \
    set -eu; \
    mkdir -p /java-libs; \
    local_count="$(find /tmp/local-java-artifacts -maxdepth 1 -type f -name 'datasurface-*.jar' | wc -l | tr -d ' ')"; \
    if [ "${local_count}" -ne 0 ] && [ "${local_count}" -ne 3 ]; then \
        echo "java-artifacts must contain all three DataSurface jars or none" >&2; \
        exit 1; \
    fi; \
    profiles="${JAVA_DEPENDENCY_PROFILES}"; \
    if [ "${local_count}" -eq 3 ]; then \
        echo "Using local thin DataSurface Java artifacts"; \
        cp /tmp/local-java-artifacts/datasurface-core.jar /java-libs/; \
        cp /tmp/local-java-artifacts/datasurface-hsm-aws.jar /java-libs/; \
        cp /tmp/local-java-artifacts/datasurface-hsm-azure.jar /java-libs/; \
    else \
        if [ -z "${DATASURFACE_VERSION}" ]; then \
            echo "DATASURFACE_VERSION is required" >&2; \
            exit 1; \
        fi; \
        if [ ! -s /run/secrets/gitlab_package_token ]; then \
            echo "BuildKit secret gitlab_package_token is required" >&2; \
            exit 1; \
        fi; \
        export GITLAB_PACKAGE_TOKEN="$(cat /run/secrets/gitlab_package_token)"; \
        profiles="${profiles:+${profiles},}datasurface"; \
        case ",${JAVA_DEPENDENCY_PROFILES}," in *,aws,*) profiles="${profiles},datasurface-aws" ;; esac; \
        case ",${JAVA_DEPENDENCY_PROFILES}," in *,azure,*) profiles="${profiles},datasurface-azure" ;; esac; \
    fi; \
    mvn -B -ntp \
        --settings /build/settings.xml \
        -f /build/pom.xml \
        -P"${profiles}" \
        -Ddatasurface.version="${DATASURFACE_VERSION#v}" \
        -Dgitlab.maven.repository="https://gitlab.com/api/v4/projects/${GITLAB_PROJECT_ID}/packages/maven" \
        org.apache.maven.plugins:maven-dependency-plugin:3.8.1:copy-dependencies \
        -DincludeScope=runtime \
        -DoutputDirectory=/java-libs; \
    if [ "${local_count}" -eq 0 ]; then \
        for artifact in datasurface-core; do \
            versioned="/java-libs/${artifact}-${DATASURFACE_VERSION#v}.jar"; \
            test -s "${versioned}"; \
            mv "${versioned}" "/java-libs/${artifact}.jar"; \
        done; \
        case ",${JAVA_DEPENDENCY_PROFILES}," in \
            *,aws,*) mv "/java-libs/datasurface-hsm-aws-${DATASURFACE_VERSION#v}.jar" /java-libs/datasurface-hsm-aws.jar ;; \
        esac; \
        case ",${JAVA_DEPENDENCY_PROFILES}," in \
            *,azure,*) mv "/java-libs/datasurface-hsm-azure-${DATASURFACE_VERSION#v}.jar" /java-libs/datasurface-hsm-azure.jar ;; \
        esac; \
    fi; \
    test -s /java-libs/datasurface-core.jar; \
    case ",${JAVA_DEPENDENCY_PROFILES}," in *,aws,*) test -s /java-libs/datasurface-hsm-aws.jar ;; esac; \
    case ",${JAVA_DEPENDENCY_PROFILES}," in *,azure,*) test -s /java-libs/datasurface-hsm-azure.jar ;; esac

FROM ${BASE_IMAGE}

ARG DATASURFACE_VERSION
ARG GITLAB_PROJECT_ID=77796931
ARG PUBLIC_PYPI_INDEX_URL=https://pypi.org/simple
ARG DATASURFACE_EXTRAS=datahub
ARG JAVA_DEPENDENCY_PROFILES=postgresql,sqlserver,snowflake,trino,aws,azure

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    DATASURFACE_VERSION=${DATASURFACE_VERSION} \
    DATASURFACE_JAVA_PROFILES=${JAVA_DEPENDENCY_PROFILES}

WORKDIR /app

COPY scripts/verify_install.py /tmp/datasurface-builder/verify_install.py

# The same read-only GitLab credential used by Maven is mounted for this step
# only. pip resolves all non-DataSurface Python dependencies from the configured
# customer/public Python index.
RUN --mount=type=bind,from=local-wheels,source=/wheelhouse,target=/tmp/local-wheelhouse,ro \
    --mount=type=secret,id=gitlab_package_token,required=false \
    set -eu; \
    mkdir -p /tmp/datasurface-wheelhouse; \
    local_wheel="$(find /tmp/local-wheelhouse -maxdepth 1 -type f -name 'datasurface-*.whl' -print -quit)"; \
    if [ -n "${local_wheel}" ]; then \
        echo "Using local DataSurface wheel: ${local_wheel}"; \
        cp "${local_wheel}" /tmp/datasurface-wheelhouse/; \
    else \
        if [ -z "${DATASURFACE_VERSION}" ]; then \
            echo "DATASURFACE_VERSION is required" >&2; \
            exit 1; \
        fi; \
        if [ -z "${GITLAB_PROJECT_ID}" ]; then \
            echo "GITLAB_PROJECT_ID is required" >&2; \
            exit 1; \
        fi; \
        if [ ! -s /run/secrets/gitlab_package_token ]; then \
            echo "BuildKit secret gitlab_package_token is required" >&2; \
            exit 1; \
        fi; \
        package_version="${DATASURFACE_VERSION#v}"; \
        netrc="$(mktemp)"; \
        printf 'machine gitlab.com\n  login __token__\n  password %s\n' \
            "$(cat /run/secrets/gitlab_package_token)" > "${netrc}"; \
        NETRC="${netrc}" python -m pip download \
            --dest /tmp/datasurface-wheelhouse \
            --no-deps \
            --only-binary=:all: \
            --index-url "https://gitlab.com/api/v4/projects/${GITLAB_PROJECT_ID}/packages/pypi/simple" \
            "datasurface==${package_version}"; \
        rm -f "${netrc}"; \
    fi; \
    wheel="$(find /tmp/datasurface-wheelhouse -maxdepth 1 -type f -name 'datasurface-*.whl' -print -quit)"; \
    if [ -z "${wheel}" ]; then \
        echo "No DataSurface wheel was downloaded" >&2; \
        exit 1; \
    fi; \
    requirement="${wheel}"; \
    if [ -n "${DATASURFACE_EXTRAS}" ]; then \
        requirement="${wheel}[${DATASURFACE_EXTRAS}]"; \
    fi; \
    python -m pip install --index-url "${PUBLIC_PYPI_INDEX_URL}" "${requirement}"; \
    rm -rf /tmp/datasurface-wheelhouse

COPY --from=java-dependencies /java-libs/ /app/java/lib/

RUN mkdir -p /workspace/model \
    && DATASURFACE_EXTRAS="${DATASURFACE_EXTRAS}" python /tmp/datasurface-builder/verify_install.py \
    && python -m pip check \
    && rm -rf /tmp/datasurface-builder

WORKDIR /workspace/model

CMD ["python", "-c", "import datasurface; print('DataSurface compiled runtime ready')"]
