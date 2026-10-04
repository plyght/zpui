#!/usr/bin/env python3
"""Module docstring."""
from __future__ import annotations
import os, sys

@dataclass(frozen=True)
class Point(Base, metaclass=Meta):
    x: int = 0
    def norm(self, *args, scale: float = 1.0, **kw) -> float:
        # comment
        return (self.x ** 2) ** 0.5 * scale if args else None

async def main():
    data = [i for i in range(10) if i % 2 == 0]
    print(f"value={data!r:>10} {os.sep}", b"bytes", r"\d+", True, False, None)
    lambda q: q + 1
    await asyncio.sleep(1)
