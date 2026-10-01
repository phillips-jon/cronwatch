"""Deprecated: ``cronwatch.run_handle`` (RunHandle, which is
cronwatch.RunHandle) is internal, as ``cronwatch._run_handle``. Its
names still work, each warning with a DeprecationWarning, until 1.0 removes the module."""

from ._deprecated import module

__getattr__, __dir__ = module(__name__, "cronwatch._run_handle")
