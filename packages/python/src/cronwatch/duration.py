"""Deprecated: ``cronwatch.duration`` (durations: parse_duration and
format_duration are cronwatch.parse_duration and cronwatch.format_duration)
is internal, as ``cronwatch._duration``. Its names still work, each warning with a DeprecationWarning, until 1.0 removes the module."""

from ._deprecated import module

__getattr__, __dir__ = module(__name__, "cronwatch._duration")
