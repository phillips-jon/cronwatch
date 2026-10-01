"""Deprecated: ``cronwatch.handler`` (job.handler()'s handler) is internal from
1.0, as ``cronwatch._handler``. Its names still work through 1.x, each
warning with a DeprecationWarning, and the module goes in 2.0."""

from ._deprecated import module

__getattr__, __dir__ = module(__name__, "cronwatch._handler")
