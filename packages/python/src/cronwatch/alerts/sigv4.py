"""Deprecated: ``cronwatch.alerts.sigv4`` (AWS Signature Version 4) is internal
from 1.0, as ``cronwatch.alerts._sigv4``. Its names still work through 1.x,
each warning with a DeprecationWarning, and the module goes in 2.0."""

from .._deprecated import module

__getattr__, __dir__ = module(__name__, "cronwatch.alerts._sigv4")
