from __future__ import annotations

import sys


def is_tty() -> bool:
    try:
        return sys.stdout.isatty()
    except Exception:
        return False


def confirm(prompt: str, default_yes: bool = True) -> bool:
    if not is_tty():
        return default_yes
    yn = "Y/n" if default_yes else "y/N"
    while True:
        resp = input(f"{prompt} [{yn}] ").strip().lower()
        if not resp:
            return default_yes
        if resp in {"y", "yes"}:
            return True
        if resp in {"n", "no"}:
            return False

