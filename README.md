# DataSurface customer image builder

This repository builds a source-minimized DataSurface runtime image on top of a
customer-approved base image. DataSurface distributes only its compiled Python
wheel and thin Java jars. pip and Maven resolve every third-party dependency by
version reference during the customer's image build. The build never accesses
the customer's model repository.

The private artifacts come from two registries in the same GitLab project:

- the compiled `datasurface` wheel from GitLab PyPI;
- `com.datasurface:datasurface-*` thin jars and their dependency POMs from
  GitLab Maven.

One read-only GitLab package token authenticates both downloads. The secret is
mounted only in the relevant BuildKit steps and is not stored in the image.
Third-party components remain governed by their own licenses; DataSurface does
not include or license those components as part of its wheel or thin jars.

## Build and load locally

The default `python:3.12` base is a working reference for Python workloads. Set
`BASE_IMAGE` to the customer's approved image; Java DataTransformers additionally
require Java 25 in that image, as described by the base-image contract.

```bash
export DATASURFACE_VERSION=1.7.1
export BASE_IMAGE=registry.example.com/approved/python-java:3.12-25
export GITLAB_PACKAGE_TOKEN='read-only-package-token'

./build-image.sh
docker run --rm datasurface-local:1.7.1
```

The token requires read-only access to the GitLab PyPI and Maven package
registries. The builder defaults to DataSurface's package project, GitLab
project `77796931`; `GITLAB_PROJECT_ID` remains overridable for a mirror.

Set `PUBLIC_PYPI_INDEX_URL` and `MAVEN_REPOSITORY_URL` to customer-approved
package mirrors. Those repositories provide third-party dependencies; they do
not provide DataSurface code.

## DataSurface GitLab registry settings

The private DataSurface package project must remain a first-party-only source:

- disable PyPI package-request forwarding for the project/group;
- do not enable Maven Central forwarding, a virtual Maven registry, or a GitLab
  dependency proxy for the DataSurface Maven repository;
- publish only `datasurface` and `com.datasurface:*` artifacts there.

These are GitLab project/group settings. The Docker build cannot enforce them.
The builder deliberately downloads the wheel with `--no-deps`, then installs the
local wheel against `PUBLIC_PYPI_INDEX_URL`. Maven uses GitLab only for the
`com.datasurface` profiles and uses `MAVEN_REPOSITORY_URL` as the mirror for all
other repositories.

## Build and push to a customer registry

Authenticate Docker using the customer's normal mechanism, then set the output
image name. Registry credentials stay with Docker or the CI runner and are not
passed into the image build.

```bash
docker login registry.customer.example

export IMAGE_NAME=registry.customer.example/data-platform/datasurface
export IMAGE_TAG=1.7.1-company.1
export PLATFORMS=linux/amd64
export PUSH_IMAGE=true

./build-image.sh
```

Customers may modify the Dockerfile to install approved certificates, security
agents, labels, users, or operating-system packages. See
[BASE_IMAGE_CONTRACT.md](BASE_IMAGE_CONTRACT.md) for the required runtime
contract.

## Test unpublished artifacts

Copy one Linux wheel into `wheelhouse/` and the three thin Java jars into
`java-artifacts/`. The build then needs no GitLab credentials:

```bash
cp /path/to/datasurface-*.whl wheelhouse/
cp /path/to/datasurface-core.jar java-artifacts/
cp /path/to/datasurface-hsm-aws.jar java-artifacts/
cp /path/to/datasurface-hsm-azure.jar java-artifacts/
DATASURFACE_VERSION=1.7.1.dev1 ./build-image.sh
```

The build verifies that operational implementation modules are compiled, Python
source is restricted to the approved facade/reflection/shim allowlist, the wheel
contains no Java jars, every DataSurface jar contains only `com.datasurface`
classes, the license verification key is present, and `/workspace/model` is
empty.

## Java dependency selection

The public [java-dependencies/pom.xml](java-dependencies/pom.xml) is a dependency
manifest, not a binary bundle. By default the image resolves PostgreSQL, SQL
Server, Snowflake, Trino, AWS KMS, and Azure Key Vault support. Override the
comma-separated profile list when a customer needs a smaller set:

```bash
export JAVA_DEPENDENCY_PROFILES=postgresql,aws
```

The `mysql`, `oracle`, and `db2` profiles are intentionally excluded by default.
Customers should enable them only after approving the applicable vendor terms:

```bash
export JAVA_DEPENDENCY_PROFILES=postgresql,aws,mysql
```

For a smaller image that does not need DataHub export support, set
`DATASURFACE_EXTRAS=`. The default is `datahub`.

For Python, the wheel's `Requires-Dist` metadata is the corresponding dependency
manifest. It is downloaded with `--no-deps`; only the later local-wheel install
resolves those references from `PUBLIC_PYPI_INDEX_URL`.
