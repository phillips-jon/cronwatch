"""Names that were public by accident before 0.11, now internal. Each still
answers under its old name, warning with a DeprecationWarning, until 1.0
removes it (see the docs' Deprecated section)."""

from __future__ import annotations

import importlib
import warnings
from collections.abc import Callable, Mapping
from typing import Any

__all__: list[str] = []


def module(old: str, new: str) -> tuple[Callable[[str], Any], Callable[[], list[str]]]:
    """A module's ``__getattr__`` and ``__dir__`` that hand out the names of
    ``new``, the module ``old`` became, warning on each use."""

    def __getattr__(name: str) -> Any:
        if name.startswith("__") and name != "__all__":
            raise AttributeError(name)
        warnings.warn(f"{old} is internal and deprecated (it is removed in 1.0): use what the cronwatch package documents", DeprecationWarning, stacklevel=2)
        return getattr(importlib.import_module(new), name)

    def __dir__() -> list[str]:
        return sorted(vars(importlib.import_module(new)))

    return __getattr__, __dir__


def names(module_name: str, scope: Mapping[str, Any], renamed: Mapping[str, str]) -> Callable[[str], Any]:
    """A module's ``__getattr__`` for public names it renamed: each old name
    gives the new one's value, warning that it is deprecated."""

    def __getattr__(name: str) -> Any:
        new = renamed.get(name)
        if new is None:
            raise AttributeError(f"module {module_name!r} has no attribute {name!r}")
        warnings.warn(f"{module_name}.{name} is internal and deprecated (it is removed in 1.0)", DeprecationWarning, stacklevel=2)
        return scope[new]

    return __getattr__
