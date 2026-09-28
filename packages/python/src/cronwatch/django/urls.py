"""The dashboard's URLs: include them where it should live.

    urlpatterns = [..., path("cronwatch/", include("cronwatch.django.urls"))]

Every path under that prefix goes to the dashboard, which answers it as the
SDK's routes do (pages, the JSON API, the app shell, and its own 404s).
"""

from __future__ import annotations

from django.urls import re_path

from .views import dashboard

app_name = "cronwatch"
urlpatterns = [re_path(r"^(?P<path>.*)\Z", dashboard, name="dashboard")]
