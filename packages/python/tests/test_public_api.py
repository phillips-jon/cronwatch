"""The public API, written out in api.txt so that a change to it is a line of
the diff. Every module whose name has no leading underscore and that
declares ``__all__`` is listed, with each name in it: functions with their
signatures, classes with their public methods and annotated fields, and
constants. The report reads the source with ``ast`` and imports nothing, so
it is the same with or without the optional dependencies.

When the test fails, the public API changed. Rewrite the file with

    CRONWATCH_WRITE_API=1 uv run pytest tests/test_public_api.py

read the diff, and record the change in CHANGELOG.md (under Unreleased) in
the same commit. Removing or changing a line is a breaking change, which
waits for a major release (site/docs/stability.md)."""

from __future__ import annotations

import ast
import os
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "src"
API = Path(__file__).resolve().parent.parent / "api.txt"
KEPT_DUNDERS = {"__init__", "__call__", "__enter__", "__exit__", "__aenter__", "__aexit__", "__iter__", "__aiter__"}


def _module_name(path: Path) -> str:
    parts = list(path.relative_to(SRC).with_suffix("").parts)
    if parts[-1] == "__init__":
        parts.pop()
    return ".".join(parts)


def _public(path: Path) -> bool:
    return not any(part.startswith("_") and part != "__init__.py" for part in path.relative_to(SRC).parts)


def _parse(module: str) -> ast.Module | None:
    base = SRC.joinpath(*module.split("."))
    for path in (base.with_suffix(".py"), base / "__init__.py"):
        if path.exists():
            return ast.parse(path.read_text(encoding="utf-8"))
    return None


def _all(tree: ast.Module) -> list[str] | None:
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "__all__" for t in node.targets):
            return [ast.literal_eval(e) for e in node.value.elts]  # type: ignore[attr-defined]
    return None


def _resolve(module: str, level: int, name: str | None, package: str) -> str:
    if level == 0:
        return name or ""
    parts = package.split(".")
    parts = parts[: len(parts) - level + 1]
    return ".".join(parts + ([name] if name else []))


def _signature(node: ast.FunctionDef | ast.AsyncFunctionDef) -> str:
    prefix = "async def" if isinstance(node, ast.AsyncFunctionDef) else "def"
    returns = f" -> {ast.unparse(node.returns)}" if node.returns else ""
    decorators = "".join(f"@{ast.unparse(d)} " for d in node.decorator_list if ast.unparse(d) in {"staticmethod", "classmethod", "property"})
    return f"{decorators}{prefix} {node.name}({ast.unparse(node.args)}){returns}"


def _describe(name: str, module: str, depth: int = 0) -> list[str]:
    """The lines for one exported name, following re-exports inside the package."""
    tree = _parse(module)
    if tree is None or depth > 5:
        return [f"{name} (from {module})"]
    is_package = SRC.joinpath(*module.split("."), "__init__.py").exists()
    package = module if is_package else module.rpartition(".")[0]
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name:
            return [_signature(node)]
        if isinstance(node, ast.ClassDef) and node.name == name:
            bases = ", ".join(ast.unparse(b) for b in node.bases + node.keywords)  # type: ignore[operator]
            lines = [f"class {name}({bases})" if bases else f"class {name}"]
            for item in node.body:
                if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)) and (not item.name.startswith("_") or item.name in KEPT_DUNDERS):
                    lines.append(f"    {_signature(item)}")
                elif isinstance(item, ast.AnnAssign) and isinstance(item.target, ast.Name) and not item.target.id.startswith("_"):
                    value = f" = {ast.unparse(item.value)}" if item.value is not None else ""
                    lines.append(f"    {item.target.id}: {ast.unparse(item.annotation)}{value}")
                elif isinstance(item, ast.Assign) and all(isinstance(t, ast.Name) and not t.id.startswith("_") for t in item.targets):
                    lines.append(f"    {' = '.join(t.id for t in item.targets)} = {ast.unparse(item.value)}")  # type: ignore[attr-defined]
            return lines
        if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.target.id == name:
            return [f"{name}: {ast.unparse(node.annotation)}"]
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            # The version changes with every release; that it is there is the API.
            return [f"{name}: str" if name == "__version__" else f"{name} = {ast.unparse(node.value)}"]
        if isinstance(node, ast.ImportFrom):
            for alias in node.names:
                if (alias.asname or alias.name) != name:
                    continue
                source = _resolve(module, node.level, node.module, package)
                if node.level == 0 and not source.startswith("cronwatch"):
                    return [f"{name} (from {source})"]
                if _parse(f"{source}.{alias.name}") is not None:
                    return [f"module {name}"]
                return _describe(alias.name, source, depth + 1) if alias.name == name else [f"{name} = {alias.name}", *_describe(alias.name, source, depth + 1)[1:]]
        if isinstance(node, ast.Import):
            for alias in node.names:
                if (alias.asname or alias.name) == name:
                    return [f"module {name}"]
    if _parse(f"{module}.{name}") is not None:
        return [f"module {name}"]
    return [f"{name}"]


def report() -> str:
    out = []
    for path in sorted(SRC.rglob("*.py")):
        if not _public(path):
            continue
        module = _module_name(path)
        names = _all(ast.parse(path.read_text(encoding="utf-8")))
        if names is None:
            continue
        lines = [f"# {module}"]
        for name in sorted(names):
            lines.extend(_describe(name, module))
        out.append("\n".join(lines))
    return "\n\n".join(out) + "\n"


def test_public_api_is_recorded() -> None:
    text = report()
    if os.environ.get("CRONWATCH_WRITE_API"):
        API.write_text(text, encoding="utf-8")
    assert API.exists(), "api.txt is missing: run CRONWATCH_WRITE_API=1 uv run pytest tests/test_public_api.py"
    assert API.read_text(encoding="utf-8") == text, (
        "The public API changed. Run CRONWATCH_WRITE_API=1 uv run pytest tests/test_public_api.py, "
        "review the diff of api.txt and record the change in CHANGELOG.md."
    )
