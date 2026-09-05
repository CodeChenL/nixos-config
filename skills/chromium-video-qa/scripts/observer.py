#!/usr/bin/python3 -IB
from __future__ import annotations

import errno
import fcntl
import os
import re
import stat
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Final

INSTALLED: Final = Path('/usr/local/libexec/chromium-qa-observer')
HOST_SCOPE: Final = Path('/etc/chromium-qa-observer.namespaces')
PROC: Final = Path('/proc')
REQUIRED_CAPS: Final = (1 << 2) | (1 << 19) | (1 << 21)


@dataclass(frozen=True, slots=True)
class UnknownObservation(Exception):
    reason: str

    def __str__(self) -> str:
        return self.reason


@dataclass(frozen=True, slots=True)
class Process:
    pid: int
    start: int
    session: int
    gpu: bool
    profile: bool
    chromium: bool
    owner: bool


def authority(namespace: str) -> None:
    if os.geteuid() != 0 or not sys.flags.isolated or not sys.dont_write_bytecode:
        raise UnknownObservation('root and isolated no-bytecode Python required')
    for artifact in (INSTALLED, HOST_SCOPE):
        for entry in (artifact, *artifact.parents):
            info = entry.lstat()
            if info.st_uid != 0 or info.st_mode & 0o022 or stat.S_ISLNK(info.st_mode):
                raise UnknownObservation('observer installation is not root-owned and immutable to users')
    if Path(sys.argv[0]) != INSTALLED:
        raise UnknownObservation('observer must run from the fixed installation path')
    status = dict(line.split(':', 1) for line in (PROC / 'self/status').read_text().splitlines())
    if int(status['CapEff'].strip(), 16) & REQUIRED_CAPS != REQUIRED_CAPS:
        raise UnknownObservation('missing DAC_READ_SEARCH, SYS_PTRACE or SYS_ADMIN')
    if (PROC / 'self/uid_map').read_text().split() != ['0', '0', '4294967295']:
        raise UnknownObservation('non-initial user namespace')
    scope = [str((PROC / f'self/ns/{kind}').readlink()) for kind in ('pid', 'user')]
    scope.append((PROC / 'sys/kernel/random/boot_id').read_text().strip())
    if HOST_SCOPE.read_text().split() != scope:
        raise UnknownObservation('host namespace/boot attestation mismatch')
    for kind in ('pid', 'user'):
        own = PROC / f'self/ns/{kind}'
        if own.readlink() != (PROC / f'1/ns/{kind}').readlink():
            raise UnknownObservation('observer and host init namespaces differ')
        with own.open('rb') as handle:
            try:
                parent = fcntl.ioctl(handle, 0xB702)
            except OSError as error:
                if error.errno != errno.EPERM:
                    raise UnknownObservation('cannot prove initial namespace') from error
            else:
                os.close(parent)
                raise UnknownObservation('nested namespace')
    if str((PROC / 'self/ns/pid').readlink()) != namespace:
        raise UnknownObservation('caller and observer PID namespaces differ')
    mounts = [line.split() for line in (PROC / 'self/mountinfo').read_text().splitlines()]
    proc_mounts = [fields for fields in mounts if fields[4] == '/proc']
    if len(proc_mounts) != 1:
        raise UnknownObservation('ambiguous proc mount')
    fields = proc_mounts[0]
    separator = fields.index('-')
    options = (fields[5] + ',' + fields[separator + 3]).split(',')
    if fields[separator + 1] != 'proc' or any(
        option.startswith(('hidepid=', 'subset=')) and option not in ('hidepid=0', 'subset=all')
        for option in options
    ):
        raise UnknownObservation('restricted proc mount')


def identity(entry: Path) -> tuple[int, int]:
    fields = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
    return int(fields[3]), int(fields[19])


def inspect_process(entry: Path, device: int | None, profile: str) -> Process | None:
    try:
        session, start = identity(entry)
        args = (entry / 'cmdline').read_bytes().split(b'\0')
        if not any(args):
            fields = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
            if fields[0] not in ('Z', 'X') and not int(fields[6]) & 0x00200000:
                raise UnknownObservation('live userspace command line is opaque')
        owner = False
        tables = [task / 'fd' for task in (entry / 'task').iterdir()]
        tables.append(entry / 'map_files')
        for table in tables:
            try:
                descriptors = list(table.iterdir())
            except FileNotFoundError:
                if table.name == 'fd':
                    try:
                        table.parent.stat()
                    except FileNotFoundError:
                        continue
                raise
            for descriptor in descriptors:
                try:
                    info = descriptor.stat()
                except FileNotFoundError:
                    try:
                        descriptor.lstat()
                    except FileNotFoundError:
                        continue
                    raise UnknownObservation('still-present descriptor target is opaque')
                if device is not None and stat.S_ISCHR(info.st_mode) and info.st_rdev == device:
                    owner = True
        if identity(entry) != (session, start):
            raise UnknownObservation('process identity changed during observation')
        return Process(int(entry.name), start, session, b'--type=gpu-process' in args,
                       os.fsencode('--user-data-dir=' + profile) in args,
                       Path(os.fsdecode(args[0])).name in ('chromium', 'chrome', 'chromium-browser'), owner)
    except OSError as error:
        try:
            entry.stat()
        except FileNotFoundError:
            return None
        raise UnknownObservation(f'still-present process {entry.name} unreadable: {error}') from error


def snapshot(device_path: str, profile: str) -> list[Process]:
    device = None
    if device_path != '-':
        info = Path(device_path).stat()
        if not stat.S_ISCHR(info.st_mode):
            raise UnknownObservation('video device is not a character device')
        device = info.st_rdev
    result: list[Process] = []
    for entry in PROC.iterdir():
        if entry.name.isdecimal():
            process = inspect_process(entry, device, profile)
            if process is not None:
                result.append(process)
    return result


def main() -> int:
    try:
        if len(sys.argv) != 6:
            raise UnknownObservation('usage: observer snapshot|processes PID_NAMESPACE DEVICE SESSION PROFILE')
        action, namespace, device, raw_session, profile = sys.argv[1:]
        if action not in ('snapshot', 'processes') or not re.fullmatch(r'pid:\[[0-9]+\]', namespace):
            raise UnknownObservation('invalid operation or namespace')
        if not re.fullmatch(r'/dev/video[0-9]+|-', device) or not raw_session.isdecimal():
            raise UnknownObservation('invalid device or session')
        if profile != '-' and not re.fullmatch(r'/tmp/chromium-video-qa\.[A-Za-z0-9]{12}/profile', profile):
            raise UnknownObservation('invalid profile')
        session = int(raw_session)
        authority(namespace)
        processes = snapshot(device, profile)
        if action == 'processes':
            print('OBSERVER_V1')
            for process in processes:
                if (session != 0 and process.session == session) or process.profile:
                    print(process.pid)
            return 0
        sample = uuid.uuid4().hex
        rows = [f'BEGIN\t{sample}\t{namespace}\t{session}']
        for process in processes:
            rows.append(f'P\t{sample}\t{process.pid}\t{process.start}\t{process.session}\t'
                        f'{int(process.gpu)}\t{int(process.profile)}\t{int(process.chromium)}')
            if process.owner:
                rows.append(f'O\t{sample}\t{process.pid}\t{process.start}')
        rows.append(f'END\t{sample}')
        print('\n'.join(rows))
        return 0
    except (UnknownObservation, OSError, ValueError, IndexError, KeyError) as error:
        print(f'UNKNOWN: {error}', file=sys.stderr)
        return 3


if __name__ == '__main__':
    sys.exit(main())
