"""Deprecated: ``cronwatch.format`` (alert titles and messages) is internal, as ``cronwatch._format``. Its names still work, each warning with a DeprecationWarning, until 1.0 removes the module."""

from ._deprecated import module

__getattr__, __dir__ = module(__name__, "cronwatch._format")
