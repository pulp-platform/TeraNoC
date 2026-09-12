#!/usr/bin/env python3
"""Compatibility entry point; use generate.py for all dashboard inputs."""
from trace_dashboard.cli import main
# Retain imports used by existing callers while packaging lives in one module.
from trace_dashboard.packaging import full_template, packed

if __name__ == '__main__':
  main()
