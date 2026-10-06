"""Cooperative cancellation token, mirroring CancellationToken.swift."""
from __future__ import annotations

import threading
import uuid
from typing import Callable


class CancellationToken:
    def __init__(self) -> None:
        self._event = threading.Event()
        self._observers: dict[uuid.UUID, Callable[[], None]] = {}
        self._lock = threading.Lock()

    @property
    def is_cancelled(self) -> bool:
        return self._event.is_set()

    def cancel(self) -> None:
        observers = []
        with self._lock:
            if self._event.is_set():
                return
            self._event.set()
            observers = list(self._observers.values())
        for cb in observers:
            try:
                cb()
            except Exception:
                pass

    def observe(self, callback: Callable[[], None]) -> uuid.UUID:
        with self._lock:
            key = uuid.uuid4()
            if self._event.is_set():
                fire_now = True
            else:
                self._observers[key] = callback
                fire_now = False
        if fire_now:
            try:
                callback()
            except Exception:
                pass
        return key

    def remove_observer(self, key: uuid.UUID) -> None:
        with self._lock:
            self._observers.pop(key, None)
