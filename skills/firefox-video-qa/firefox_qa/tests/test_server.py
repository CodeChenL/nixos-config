from __future__ import annotations

import json
from http.client import HTTPConnection
from pathlib import Path

from ..json_value import load_json
from ..result_server import ResultServer


def _result(token: str) -> bytes:
    return json.dumps(
        {
            "schemaVersion": 1,
            "runToken": token,
            "scenarioId": "case",
            "mode": "full",
            "state": "ended",
            "currentTime": 6.0,
            "duration": 6.0,
            "presentedFrames": 1,
            "postSeekPresented": False,
            "frameCallbacks": [{"mediaTime": 6.0, "presentedFrames": 1}],
            "capabilities": {
                "canPlayType": "probably",
                "mediaCapabilitiesState": "available",
                "supported": True,
                "smooth": True,
                "powerEfficient": True,
                "error": None,
            },
            "quality": {
                "api": "available",
                "totalVideoFrames": {"state": "nonzero", "value": 1},
                "droppedVideoFrames": {"state": "zero", "value": 0},
                "corruptedVideoFrames": {"state": "null", "value": None},
            },
            "error": None,
        }
    ).encode()


def _post(port: int, token: str, body: bytes) -> int:
    connection = HTTPConnection("127.0.0.1", port, timeout=2)
    try:
        connection.request(
            "POST", f"/result/{token}", body, headers={"Content-Type": "application/json"}
        )
        response = connection.getresponse()
        _ = response.read()
        return response.status
    finally:
        connection.close()


def test_result_server_accepts_exact_token_and_atomically_writes_once(tmp_path: Path) -> None:
    # Given
    token = "a" * 32
    result = tmp_path / "result.json"

    # When
    with ResultServer(tmp_path, result, token, "case", "full") as server:
        status = _post(server.port, token, _result(token))
        duplicate_status = _post(server.port, token, _result(token))

    # Then
    assert status == 204
    assert duplicate_status == 409
    payload = load_json(result.read_text())
    assert isinstance(payload, dict)
    assert payload["scenarioId"] == "case"


def test_result_server_rejects_wrong_token_and_oversized_body(tmp_path: Path) -> None:
    # Given
    token = "a" * 32
    result = tmp_path / "result.json"

    # When / Then
    with ResultServer(tmp_path, result, token, "case", "full", max_body=1024) as server:
        wrong_status = _post(server.port, "b" * 32, _result(token))
        large_status = _post(server.port, token, b"x" * 1025)
    assert wrong_status == 403
    assert large_status == 413
    assert result.exists() is False
