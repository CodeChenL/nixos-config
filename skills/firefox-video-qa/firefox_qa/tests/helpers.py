from __future__ import annotations

from collections.abc import Callable


def assert_raises[E: BaseException, R](exception_type: type[E], action: Callable[[], R]) -> E:
    try:
        _ = action()
    except exception_type as error:
        return error
    raise AssertionError(f"expected {exception_type.__name__}")
