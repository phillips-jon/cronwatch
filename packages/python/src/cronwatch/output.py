"""Deprecated: ``cronwatch.output`` (the output cap and redaction:
redact_secrets is cronwatch.redact_secrets) is internal, as
``cronwatch._output``. Its names still work, each warning with a DeprecationWarning, until 1.0 removes the module."""

from ._deprecated import module

__getattr__, __dir__ = module(__name__, "cronwatch._output")
