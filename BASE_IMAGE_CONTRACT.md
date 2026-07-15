# Base image contract

The final image always starts from the customer-supplied `BASE_IMAGE`. The
builder does not install operating-system packages because package managers and
approved repositories differ between customers.

The Maven dependency-resolution stage is separately configurable with
`MAVEN_IMAGE`. Customers that restrict every build stage can replace its default
with an approved Maven/JDK image. Third-party Java libraries are copied from
that build stage into the customer-based final image.

The base image must provide:

- Linux with glibc compatible with the published DataSurface `manylinux` wheel.
- CPython 3.12 and `pip`, available as `python` and `python -m pip`.
- The Git command-line client, available as `git`, for runtime model and Git
  DataTransformer repository checkouts.
- A writable Python installation and permission to create `/app` and
  `/workspace/model` during the build.
- CA certificates for GitLab and the configured public Python package index.
- Runtime libraries required by the database drivers the customer enables.

Feature-specific requirements:

- SQL Server: unixODBC and Microsoft ODBC Driver 18.
- PostgreSQL native clients: the customer-approved `libpq` runtime.
- Java DataTransformers: a Java 25 runtime available as `java`.
- DB2: supported only where IBM's driver and architecture are available.

Alpine/musl images are not compatible with the current glibc `manylinux`
wheels. They require separately published `musllinux` wheels.

The image build creates an empty `/workspace/model`. Customer model source is
obtained from the customer's separate model repository at runtime and is never
copied into this image.
