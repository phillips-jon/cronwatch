"""Deprecated: ``cronwatch.alerts.sigv4`` (AWS Signature Version 4) is internal, as ``cronwatch.alerts._sigv4``. Its names still work, each warning with a DeprecationWarning, until 1.0 removes the module."""

from .._deprecated import module

__getattr__, __dir__ = module(__name__, "cronwatch.alerts._sigv4")
