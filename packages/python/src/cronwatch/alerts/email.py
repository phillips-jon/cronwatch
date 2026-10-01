"""Deprecated: ``cronwatch.alerts.email`` (the email channels' subject, text
and HTML) is internal, as ``cronwatch.alerts._email``. Its names
still work, each warning with a DeprecationWarning, until 1.0 removes the module."""

from .._deprecated import module

__getattr__, __dir__ = module(__name__, "cronwatch.alerts._email")
