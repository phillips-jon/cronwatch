"""The app config for INSTALLED_APPS = [..., "cronwatch.django"]."""

from __future__ import annotations

from typing import Any

from django.apps import AppConfig
from django.core.signals import setting_changed
from django.utils.module_loading import autodiscover_modules

from .._deprecated import names as _deprecated_names

__all__ = ["CronwatchConfig"]

#: The module imported from every installed app at startup, when the app has one.
_JOBS_MODULE = "cronwatch_jobs"


def _settings_changed(setting: str, **kwargs: Any) -> None:
    if setting in ("CRONWATCH", "DEBUG"):
        from . import reset

        reset()


class CronwatchConfig(AppConfig):
    name = "cronwatch.django"
    label = "cronwatch"
    verbose_name = "CronWatch"

    def ready(self) -> None:
        # The client is made on first use, from the settings as they are then,
        # so that tests overriding CRONWATCH or DEBUG get one made from theirs.
        setting_changed.connect(_settings_changed, dispatch_uid="cronwatch.django.settings_changed")
        # Each installed app's cronwatch_jobs module, when it has one, so the
        # jobs declared there are known from startup: cronwatch_check reports
        # one that has never run, as the gem's Railtie declares them at boot.
        autodiscover_modules(_JOBS_MODULE)


#: Internal names, still answering under their old public names (each
#: warning, until 1.0 removes them).
__getattr__ = _deprecated_names(__name__, globals(), {"JOBS_MODULE": "_JOBS_MODULE"})
