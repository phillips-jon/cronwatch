"""Deprecated: ``cronwatch.handler`` (job.handler()'s handler) is internal from
1.0, as ``cronwatch._handler``. Its names still work, each warning with a DeprecationWarning, until 1.0 removes the module."""

from ._deprecated import module

__getattr__, __dir__ = module(__name__, "cronwatch._handler")
