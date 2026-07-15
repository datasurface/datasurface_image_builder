#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

: "${DATASURFACE_VERSION:?Set DATASURFACE_VERSION, for example 1.7.1}"

BASE_IMAGE="${BASE_IMAGE:-python:3.12}"
MAVEN_IMAGE="${MAVEN_IMAGE:-maven:3.9-eclipse-temurin-25}"
IMAGE_NAME="${IMAGE_NAME:-datasurface-local}"
IMAGE_TAG="${IMAGE_TAG:-${DATASURFACE_VERSION}}"
PLATFORMS="${PLATFORMS:-}"
PUSH_IMAGE="${PUSH_IMAGE:-false}"
GITLAB_PROJECT_ID="${GITLAB_PROJECT_ID:-77796931}"
DATASURFACE_EXTRAS="${DATASURFACE_EXTRAS-datahub}"
PUBLIC_PYPI_INDEX_URL="${PUBLIC_PYPI_INDEX_URL:-https://pypi.org/simple}"
MAVEN_REPOSITORY_URL="${MAVEN_REPOSITORY_URL:-https://repo1.maven.org/maven2}"
JAVA_DEPENDENCY_PROFILES="${JAVA_DEPENDENCY_PROFILES:-postgresql,sqlserver,snowflake,trino,aws,azure}"

args=(
    --build-arg "BASE_IMAGE=${BASE_IMAGE}"
    --build-arg "MAVEN_IMAGE=${MAVEN_IMAGE}"
    --build-arg "DATASURFACE_VERSION=${DATASURFACE_VERSION}"
    --build-arg "GITLAB_PROJECT_ID=${GITLAB_PROJECT_ID}"
    --build-arg "DATASURFACE_EXTRAS=${DATASURFACE_EXTRAS}"
    --build-arg "PUBLIC_PYPI_INDEX_URL=${PUBLIC_PYPI_INDEX_URL}"
    --build-arg "MAVEN_REPOSITORY_URL=${MAVEN_REPOSITORY_URL}"
    --build-arg "JAVA_DEPENDENCY_PROFILES=${JAVA_DEPENDENCY_PROFILES}"
    --tag "${IMAGE_NAME}:${IMAGE_TAG}"
)

local_wheel=false
if find wheelhouse -maxdepth 1 -type f -name 'datasurface-*.whl' -print -quit | grep -q .; then
    local_wheel=true
fi

local_java_count="$(find java-artifacts -maxdepth 1 -type f -name 'datasurface-*.jar' | wc -l | tr -d ' ')"
if [ "${local_java_count}" -ne 0 ] && [ "${local_java_count}" -ne 3 ]; then
    echo "java-artifacts must contain all three DataSurface jars or none" >&2
    exit 1
fi

if [ "${local_wheel}" != "true" ] || [ "${local_java_count}" -eq 0 ]; then
    : "${GITLAB_PROJECT_ID:?Set GITLAB_PROJECT_ID when wheelhouse/ is empty}"
    GITLAB_PACKAGE_TOKEN="${GITLAB_PACKAGE_TOKEN:-${GITLAB_PYPI_TOKEN:-}}"
    : "${GITLAB_PACKAGE_TOKEN:?Set GITLAB_PACKAGE_TOKEN when local DataSurface artifacts are incomplete}"
    export GITLAB_PACKAGE_TOKEN
    args+=(--secret id=gitlab_package_token,env=GITLAB_PACKAGE_TOKEN)
fi

if [ -n "${PLATFORMS}" ] || [ "${PUSH_IMAGE}" = "true" ]; then
    command=(docker buildx build "${args[@]}")
    if [ -n "${PLATFORMS}" ]; then
        command+=(--platform "${PLATFORMS}")
    fi
    if [ "${PUSH_IMAGE}" = "true" ]; then
        command+=(--push)
    else
        command+=(--load)
    fi
else
    command=(docker build "${args[@]}")
fi

command+=(.)
"${command[@]}"
