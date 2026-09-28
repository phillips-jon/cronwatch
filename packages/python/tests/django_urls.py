"""The URLconf of tests/test_django.py's project: the dashboard under a prefix of two parts."""

from django.urls import include, path

urlpatterns = [path("ops/cronwatch/", include("cronwatch.django.urls"))]
