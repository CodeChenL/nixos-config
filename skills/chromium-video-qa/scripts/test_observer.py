from __future__ import annotations

import errno
import os
import shutil
import sys
from pathlib import Path

import pytest

import observer


@pytest.fixture
def process(tmp_path: Path) -> Path:
    entry = tmp_path / '123'
    (entry / 'task/123/fd').mkdir(parents=True)
    (entry / 'map_files').mkdir()
    fields = ['S', '1', '123', '321', *(['0'] * 15), '500']
    (entry / 'stat').write_text('123 (GPU child) ' + ' '.join(fields))
    (entry / 'cmdline').write_bytes(b'chrome\0--type=gpu-process\0')
    return entry


def test_gpu_without_profile_has_session_identity(process: Path) -> None:
    result = observer.inspect_process(process, None, '/not-present')
    assert result is not None
    assert (result.pid, result.start, result.session, result.gpu, result.profile) == (123, 500, 321, True, False)


def test_still_present_unreadable_cmdline_is_unknown(process: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    original = Path.read_bytes

    def unreadable(path: Path) -> bytes:
        if path == process / 'cmdline':
            raise PermissionError(errno.EACCES, 'opaque cmdline')
        return original(path)

    monkeypatch.setattr(Path, 'read_bytes', unreadable)
    with pytest.raises(observer.UnknownObservation, match='still-present process'):
        observer.inspect_process(process, None, '-')


def test_disappeared_process_is_not_opaque(process: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    def disappeared(_path: Path) -> bytes:
        shutil.rmtree(process)
        raise FileNotFoundError(errno.ENOENT, 'exited')

    monkeypatch.setattr(Path, 'read_bytes', disappeared)
    assert observer.inspect_process(process, None, '-') is None


def test_silently_empty_live_userspace_cmdline_is_unknown(process: Path) -> None:
    (process / 'cmdline').write_bytes(b'')
    with pytest.raises(observer.UnknownObservation, match='command line is opaque'):
        observer.inspect_process(process, None, '-')


def test_still_present_hidden_descriptor_is_unknown(process: Path) -> None:
    (process / 'task/123/fd/1').symlink_to('hidden-target')
    with pytest.raises(observer.UnknownObservation, match='descriptor target is opaque'):
        observer.inspect_process(process, None, '-')


@pytest.mark.parametrize('table', ['task/123/fd', 'map_files'])
def test_hidden_descriptor_table_is_unknown(process: Path, monkeypatch: pytest.MonkeyPatch, table: str) -> None:
    original = Path.iterdir

    def unreadable(path: Path):
        if path == process / table:
            raise PermissionError(errno.EACCES, 'opaque owners')
        return original(path)

    monkeypatch.setattr(Path, 'iterdir', unreadable)
    with pytest.raises(observer.UnknownObservation, match='still-present process'):
        observer.inspect_process(process, None, '-')


@pytest.mark.parametrize('table', ['task/456/fd', 'map_files'])
def test_thread_private_or_mapped_device_is_observed(process: Path, table: str) -> None:
    directory = process / table
    directory.mkdir(parents=True, exist_ok=True)
    (directory / '1').symlink_to('/dev/null')
    result = observer.inspect_process(process, Path('/dev/null').stat().st_rdev, '-')
    assert result is not None and result.owner


def test_reused_pid_is_unknown(process: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    values = iter([(321, 500), (321, 501)])
    monkeypatch.setattr(observer, 'identity', lambda _entry: next(values))
    with pytest.raises(observer.UnknownObservation, match='identity changed'):
        observer.inspect_process(process, None, '-')


@pytest.fixture
def authority_proc(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    proc = tmp_path / 'proc'
    (proc / 'self/ns').mkdir(parents=True)
    (proc / '1/ns').mkdir(parents=True)
    (proc / 'self/status').write_text(f'CapEff:\t{observer.REQUIRED_CAPS:x}\n')
    (proc / 'self/uid_map').write_text('0 0 4294967295\n')
    (proc / 'self/mountinfo').write_text('1 0 0:1 / /proc rw - proc proc rw\n')
    for kind in ('pid', 'user'):
        handle = tmp_path / f'{kind}:[1]'
        handle.touch()
        for prefix in ('self', '1'):
            (proc / f'{prefix}/ns/{kind}').symlink_to(handle)
    installed = tmp_path / 'observer'
    installed.touch()
    host_scope = tmp_path / 'host-scope'
    (proc / 'sys/kernel/random').mkdir(parents=True)
    (proc / 'sys/kernel/random/boot_id').write_text('test-boot')
    host_scope.write_text(' '.join(str((proc / f'self/ns/{kind}').readlink()) for kind in ('pid', 'user')) + ' test-boot')
    original = Path.lstat

    def trusted(path: Path) -> os.stat_result:
        info = list(original(path))
        info[0] &= ~0o022
        info[4] = 0
        return os.stat_result(info)

    def initial_namespace(_handle, _operation: int) -> int:
        raise PermissionError(errno.EPERM, 'initial namespace has no parent')

    monkeypatch.setattr(observer, 'PROC', proc)
    monkeypatch.setattr(observer, 'INSTALLED', installed)
    monkeypatch.setattr(observer, 'HOST_SCOPE', host_scope)
    monkeypatch.setattr(Path, 'lstat', trusted)
    monkeypatch.setattr(os, 'geteuid', lambda: 0)
    monkeypatch.setattr(observer.fcntl, 'ioctl', initial_namespace)
    monkeypatch.setattr(sys, 'argv', [str(installed)])
    return proc


def test_authority_accepts_complete_host_scope(authority_proc: Path) -> None:
    observer.authority(str((authority_proc / 'self/ns/pid').readlink()))


@pytest.mark.parametrize('restriction', ['caps', 'hidepid', 'userns', 'pidns'])
def test_authority_rejects_silent_visibility_restrictions(authority_proc: Path, restriction: str) -> None:
    match restriction:
        case 'caps':
            (authority_proc / 'self/status').write_text('CapEff:\t0\n')
        case 'hidepid':
            (authority_proc / 'self/mountinfo').write_text('1 0 0:1 / /proc rw - proc proc rw,hidepid=2\n')
        case 'userns':
            (authority_proc / 'self/uid_map').write_text('0 1000 1\n')
        case 'pidns':
            (authority_proc / '1/ns/pid').unlink()
            (authority_proc / '1/ns/pid').symlink_to('other')
    with pytest.raises(observer.UnknownObservation):
        observer.authority(str((authority_proc / 'self/ns/pid').readlink()))


def test_authority_rejects_caller_namespace_mismatch(authority_proc: Path) -> None:
    with pytest.raises(observer.UnknownObservation, match='caller and observer'):
        observer.authority('pid:[other]')


def test_authority_rejects_nested_namespace(authority_proc: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    parent = os.open(authority_proc / 'self/status', os.O_RDONLY)
    monkeypatch.setattr(observer.fcntl, 'ioctl', lambda _handle, _operation: parent)
    with pytest.raises(observer.UnknownObservation, match='nested namespace'):
        observer.authority(str((authority_proc / 'self/ns/pid').readlink()))


@pytest.mark.parametrize('claim', ['pid:[other] user:[other] test-boot', 'pid:[1] user:[1] stale-boot'])
def test_namespace_parent_eperm_cannot_replace_host_attestation(authority_proc: Path, claim: str) -> None:
    observer.HOST_SCOPE.write_text(claim)
    with pytest.raises(observer.UnknownObservation, match='attestation mismatch'):
        observer.authority(str((authority_proc / 'self/ns/pid').readlink()))
