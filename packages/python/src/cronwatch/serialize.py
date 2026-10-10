"""Deprecated: ``cronwatch.serialize`` (stored definitions) is internal from
0.11, as ``cronwatch._serialize``. Its names still work, each warning with a DeprecationWarning, until 1.0 removes the module."""

from ._deprecated import module

__getattr__, __dir__ = module(__name__, "cronwatch._serialize")
