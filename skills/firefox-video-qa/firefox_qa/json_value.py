from __future__ import annotations

import math
import re
from typing import Final, final

from .models import JsonValue

type JsonInput = str | bytes | bytearray
NUMBER: Final = re.compile(r"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")
ESCAPES: Final = {
    '"': '"',
    "\\": "\\",
    "/": "/",
    "b": "\b",
    "f": "\f",
    "n": "\n",
    "r": "\r",
    "t": "\t",
}


class JsonDecodeError(Exception):
    position: int

    def __init__(self, position: int) -> None:
        super().__init__(f"invalid JSON at position {position}")
        self.position = position


@final
class _Parser:
    text: str
    index: int

    def __init__(self, text: str) -> None:
        self.text = text
        self.index = 0

    def parse(self) -> JsonValue:
        value = self._value()
        self._whitespace()
        if self.index != len(self.text):
            raise JsonDecodeError(self.index)
        return value

    def _whitespace(self) -> None:
        while self.index < len(self.text) and self.text[self.index] in " \t\r\n":
            self.index += 1

    def _value(self) -> JsonValue:
        self._whitespace()
        if self.index >= len(self.text):
            raise JsonDecodeError(self.index)
        character = self.text[self.index]
        if character == '"':
            return self._string()
        if character == "{":
            return self._object()
        if character == "[":
            return self._array()
        if character in "-0123456789":
            return self._number()
        for literal, value in (("true", True), ("false", False), ("null", None)):
            if self.text.startswith(literal, self.index):
                self.index += len(literal)
                return value
        raise JsonDecodeError(self.index)

    def _string(self) -> str:
        self.index += 1
        value: list[str] = []
        while self.index < len(self.text):
            character = self.text[self.index]
            self.index += 1
            if character == '"':
                return "".join(value)
            if character == "\\":
                value.append(self._escape())
            elif ord(character) < 0x20:
                raise JsonDecodeError(self.index - 1)
            else:
                value.append(character)
        raise JsonDecodeError(self.index)

    def _escape(self) -> str:
        if self.index >= len(self.text):
            raise JsonDecodeError(self.index)
        character = self.text[self.index]
        self.index += 1
        escaped = ESCAPES.get(character)
        if escaped is not None:
            return escaped
        if character != "u" or self.index + 4 > len(self.text):
            raise JsonDecodeError(self.index - 1)
        digits = self.text[self.index : self.index + 4]
        if re.fullmatch(r"[0-9A-Fa-f]{4}", digits) is None:
            raise JsonDecodeError(self.index)
        self.index += 4
        codepoint = int(digits, 16)
        if 0xD800 <= codepoint <= 0xDBFF and self.text.startswith("\\u", self.index):
            low_digits = self.text[self.index + 2 : self.index + 6]
            if re.fullmatch(r"[0-9A-Fa-f]{4}", low_digits) is not None:
                low = int(low_digits, 16)
                if 0xDC00 <= low <= 0xDFFF:
                    self.index += 6
                    codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + low - 0xDC00
        return chr(codepoint)

    def _number(self) -> int | float:
        match = NUMBER.match(self.text, self.index)
        if match is None:
            raise JsonDecodeError(self.index)
        token = match.group()
        self.index = match.end()
        if "." not in token and "e" not in token.lower():
            return int(token)
        value = float(token)
        if not math.isfinite(value):
            raise JsonDecodeError(match.start())
        return value

    def _array(self) -> list[JsonValue]:
        self.index += 1
        values: list[JsonValue] = []
        self._whitespace()
        if self._consume("]"):
            return values
        while True:
            values.append(self._value())
            self._whitespace()
            if self._consume("]"):
                return values
            self._require(",")

    def _object(self) -> dict[str, JsonValue]:
        self.index += 1
        values: dict[str, JsonValue] = {}
        self._whitespace()
        if self._consume("}"):
            return values
        while True:
            self._whitespace()
            if self.index >= len(self.text) or self.text[self.index] != '"':
                raise JsonDecodeError(self.index)
            key = self._string()
            self._whitespace()
            self._require(":")
            values[key] = self._value()
            self._whitespace()
            if self._consume("}"):
                return values
            self._require(",")

    def _consume(self, expected: str) -> bool:
        if self.text.startswith(expected, self.index):
            self.index += len(expected)
            return True
        return False

    def _require(self, expected: str) -> None:
        if not self._consume(expected):
            raise JsonDecodeError(self.index)


def load_json(data: JsonInput) -> JsonValue:
    try:
        text = data if isinstance(data, str) else bytes(data).decode("utf-8")
    except UnicodeDecodeError as error:
        raise JsonDecodeError(error.start) from error
    return _Parser(text).parse()
