from pathlib import Path


BACKEND_ROOT = Path(__file__).resolve().parents[1]
REQUIREMENTS = BACKEND_ROOT / "requirements-core.txt"
CI_WORKFLOW = BACKEND_ROOT.parent / ".github" / "workflows" / "ci.yml"
COMMON_LOCK = BACKEND_ROOT / "requirements-common.lock"


def _requirement_lines() -> list[str]:
    return [
        line.strip()
        for line in REQUIREMENTS.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def test_security_sensitive_web_dependencies_are_exact_and_patched():
    requirements = set(_requirement_lines())

    assert "fastapi==0.139.0" in requirements
    assert "starlette==1.3.1" in requirements
    assert "python-multipart==0.0.32" in requirements
    assert "pydantic==2.9.2" in requirements
    assert "PyJWT[crypto]==2.13.0" in requirements
    assert "opencv-python==4.9.0.80" in requirements
    assert "Pillow==12.3.0" in requirements
    assert "pytest==9.1.1" in requirements
    assert "pytest-asyncio==1.4.0" in requirements
    assert "python-dotenv==1.2.2" in requirements
    assert not any(line.lower().startswith("python-jose") for line in requirements)
    assert not any(
        line.lower().startswith(("langchain", "langgraph", "langsmith", "openai", "ollama"))
        for line in requirements
    )


def test_ci_runs_a_bounded_python_dependency_audit():
    workflow = CI_WORKFLOW.read_text(encoding="utf-8")

    assert "pip-audit==2.10.1" in workflow
    assert "python -m pip_audit" in workflow
    assert "timeout-minutes:" in workflow
    assert "pip==26.1.2" in workflow
    assert "setuptools==81.0.0" in workflow
    assert "--ignore-vuln PYSEC-2026-3447" in workflow


def test_common_transitive_dependencies_use_exact_constraints():
    requirements = _requirement_lines()
    lock_lines = [
        line.strip()
        for line in COMMON_LOCK.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]

    assert "-c requirements-common.lock" in requirements
    assert lock_lines
    assert 'uvloop==0.22.1; sys_platform != "win32"' in lock_lines
    assert all("==" in line and ">=" not in line and "~=" not in line for line in lock_lines)
    assert not any(line.lower().startswith(("torch==", "torchvision==")) for line in lock_lines)

    workflow = CI_WORKFLOW.read_text(encoding="utf-8")
    assert "backend/requirements-common.lock" in workflow
