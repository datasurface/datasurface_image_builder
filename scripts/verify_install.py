"""Fail the image build if the installed DataSurface runtime is incomplete."""

from __future__ import annotations

import importlib
import os
from importlib import metadata, resources
from pathlib import Path
from zipfile import BadZipFile, ZipFile

from packaging.version import Version


COMPILED_MODULES = (
    "datasurface.cmd.catalog",
    "datasurface.cmd.platform",
    "datasurface.handler.action",
    "datasurface.md._safe_commands_loader_subprocess",
    "datasurface.md._safe_loader_subprocess",
    "datasurface.md.governance",
    "datasurface.platforms.yellow.jobs",
    "datasurface.platforms.yellow.jobs_cqrs",
    "datasurface.platforms.yellow.reconcile_workspace_views",
    "datasurface.platforms.yellow.transformerjob",
    "datasurface.utils.data_change_simulator",
)

SOURCE_SHIMS = (
    "datasurface.entrypoints.action",
    "datasurface.entrypoints.catalog",
    "datasurface.entrypoints.jobs",
    "datasurface.entrypoints.jobs_cqrs",
    "datasurface.entrypoints.platform",
    "datasurface.entrypoints.reconcile_workspace_views",
    "datasurface.entrypoints.safe_commands_loader",
    "datasurface.entrypoints.safe_loader",
    "datasurface.entrypoints.transformerjob",
    "datasurface.entrypoints.trigger_service",
)

SOURCE_ONLY_PREFIXES = (
    "entrypoints/",
    "mcp/",
    "md/server/",
)

SOURCE_ONLY_FILES = {
    "md/db/snowflake.py",
    "md/db/sqlserver.py",
    "md/db/trino.py",
    "md/db/vertica.py",
    "platforms/yellow/trigger_service.py",
    "platforms/yellow/yellow_events.py",
    "platforms/yellow/yellow_states.py",
}


def module_path(module_name: str) -> Path:
    module = importlib.import_module(module_name)
    path = getattr(module, "__file__", None)
    if not path:
        raise SystemExit(f"{module_name} has no filesystem path")
    return Path(path)


def verify_datasurface_jar(path: Path) -> None:
    try:
        with ZipFile(path) as archive:
            names = [name for name in archive.namelist() if not name.endswith("/")]
    except BadZipFile as error:
        raise SystemExit(f"Invalid DataSurface jar {path}: {error}") from error

    class_files = [name for name in names if name.endswith(".class")]
    if not class_files:
        raise SystemExit(f"DataSurface jar contains no classes: {path}")
    foreign_classes = [
        name for name in class_files if not name.startswith("com/datasurface/")
    ]
    if foreign_classes:
        raise SystemExit(
            f"DataSurface jar contains third-party classes: {path}: "
            + ", ".join(foreign_classes[:10])
        )

    unexpected_payloads = [
        name
        for name in names
        if not name.startswith("com/datasurface/")
        and name != "META-INF/MANIFEST.MF"
        and not name.startswith("META-INF/maven/com.datasurface/")
    ]
    if unexpected_payloads:
        raise SystemExit(
            f"DataSurface jar contains unexpected payloads: {path}: "
            + ", ".join(unexpected_payloads[:10])
        )


def main() -> None:
    actual_version = metadata.version("datasurface")
    expected_version = os.environ.get("DATASURFACE_VERSION", "").removeprefix("v")
    if expected_version and Version(actual_version) != Version(expected_version):
        raise SystemExit(
            f"Installed DataSurface {actual_version}, expected {expected_version}"
        )

    enabled_extras = {
        extra.strip()
        for extra in os.environ.get("DATASURFACE_EXTRAS", "").split(",")
        if extra.strip()
    }

    for module_name in COMPILED_MODULES:
        if module_name == "datasurface.cmd.catalog" and "datahub" not in enabled_extras:
            continue
        path = module_path(module_name)
        if path.suffix not in {".so", ".pyd"}:
            raise SystemExit(f"{module_name} is not compiled: {path}")

    for module_name in SOURCE_SHIMS:
        if module_name == "datasurface.entrypoints.catalog" and "datahub" not in enabled_extras:
            continue
        path = module_path(module_name)
        if path.suffix != ".py":
            raise SystemExit(f"{module_name} is not a source shim: {path}")

    key_package = resources.files("datasurface.keys")
    if not any(entry.name.endswith(".asc") for entry in key_package.iterdir()):
        raise SystemExit("DataSurface wheel contains no license verification public key")

    java_profiles = {
        profile.strip()
        for profile in os.environ.get("DATASURFACE_JAVA_PROFILES", "").split(",")
        if profile.strip()
    }
    required_jars = ["datasurface-core.jar"]
    if "aws" in java_profiles:
        required_jars.append("datasurface-hsm-aws.jar")
    if "azure" in java_profiles:
        required_jars.append("datasurface-hsm-azure.jar")

    for jar_name in required_jars:
        jar = Path("/app/java/lib") / jar_name
        if not jar.is_file() or jar.stat().st_size == 0:
            raise SystemExit(f"Missing staged Java runtime asset: {jar}")
        verify_datasurface_jar(jar)

    model_workspace = Path("/workspace/model")
    if any(model_workspace.iterdir()):
        raise SystemExit("/workspace/model must be empty in the runtime image")

    import datasurface

    root = Path(datasurface.__file__).resolve().parent
    if list(root.rglob("*.c")):
        raise SystemExit("Generated C source was packaged in the DataSurface wheel")
    if list(root.rglob("*.jar")):
        raise SystemExit("The DataSurface Python wheel must not contain Java jars")
    if any("tests" in path.parts for path in root.rglob("*")):
        raise SystemExit("Test files were packaged in the DataSurface wheel")

    unexpected_source: list[str] = []
    for path in root.rglob("*.py"):
        relative = path.relative_to(root).as_posix()
        if path.name == "__init__.py":
            continue
        if relative in SOURCE_ONLY_FILES:
            continue
        if any(relative.startswith(prefix) for prefix in SOURCE_ONLY_PREFIXES):
            continue
        unexpected_source.append(relative)
    if unexpected_source:
        raise SystemExit(
            "Unexpected DataSurface Python source: " + ", ".join(sorted(unexpected_source))
        )

    print(f"Verified DataSurface {actual_version} at {root}")
    print(f"  compiled extensions: {len(list(root.rglob('*.so')))}")
    print(f"  Python source files: {len(list(root.rglob('*.py')))}")
    print(f"  separately installed Java jars: {len(list(Path('/app/java/lib').glob('*.jar')))}")


if __name__ == "__main__":
    main()
