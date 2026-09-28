"""The app config for INSTALLED_APPS = [..., "cronwatch.django"]."""

from __future__ import annotations

from typing import Any

from django.apps import AppConfig
from django.core.signals import setting_changed


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
