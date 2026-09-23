#!/usr/bin/env python3
"""Linux management tests, isolated paths and mock Docker/systemd only."""
import fcntl
import gzip
import hashlib
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o700)


with tempfile.TemporaryDirectory(prefix="ibsng-manager-tests-") as temporary:
    root = Path(temporary)
    config = root / 'config.env'
    manager = root / 'bin/ibsng-backup'
    worker = root / 'bin/worker'
    offline = root / 'lib/install.sh'
    units = root / 'units'
    backups = root / 'backups'
    snapshots = root / 'snapshots'
    mock = root / 'mock'
    for path in (units, backups, snapshots, mock):
        path.mkdir()
    source = (HERE / 'manager.sh').read_text()
    for old, new in {
        '/etc/ibsng-backup-telegram.env': config,
        '/usr/local/sbin/ibsng-backup-telegram': worker,
        '/usr/local/lib/ibsng-backup/install.sh': offline,
        '/usr/local/bin/ibsng-backup': manager,
        '/etc/systemd/system': units,
        '/var/backups/ibsng-backup-uninstall-': str(snapshots) + '/saved-',
    }.items():
        source = source.replace(old, str(new))
    source = source.replace('[[ "$EUID" -eq 0 ]]', 'true')
    write(manager, source)
    write(config, f'''IBSNG_CONTAINER=test-db
IBSNG_DB=IBSng
BACKUP_DIR={backups}
LOCK_FILE={root}/lock
TELEGRAM_BOT_TOKEN=123:SECRET_TEST_VALUE
TELEGRAM_SEND=true
''')
    write(worker, '#!/bin/bash\nprintf "%s\\n" "$*" >> "$WORKER_LOG"\nexit "${WORKER_FAIL:-0}"\n')
    write(offline, '#!/bin/bash\nexit 0\n')
    for suffix in ('service', 'timer'):
        write(units / ('ibsng-backup-telegram.' + suffix), '# test unit\n')
    write(mock / 'systemctl', '''#!/bin/bash
echo "$*" >> "$SYSTEM_LOG"
case "$1" in
 show) echo "${ACTIVE_STATE:-inactive}" ;;
 enable) touch "$TIMER_STATE" ;;
 disable) rm -f "$TIMER_STATE" ;;
 is-active|is-enabled) test -f "$TIMER_STATE" ;;
 *) exit 0 ;;
esac
''')
    write(mock / 'docker', '''#!/bin/bash
echo "$*" >> "$DOCKER_LOG"
if [[ "$*" == *createdb* ]]; then exit 0
elif [[ "$*" == *'FROM pg_database'* ]]; then echo "${DB_EXISTS:-0}"
elif [[ "$*" == *'pg_catalog.pg_class'* ]]; then echo 3
else cat > "$IMPORT_LOG"; exit "${IMPORT_FAIL:-0}"
fi
''')
    env = dict(os.environ, PATH=str(mock) + ':' + os.environ['PATH'],
               WORKER_LOG=str(root / 'worker.log'), SYSTEM_LOG=str(root / 'system.log'),
               TIMER_STATE=str(root / 'timer'), DOCKER_LOG=str(root / 'docker.log'), IMPORT_LOG=str(root / 'import.sql'))
    passed = 0

    def run(args, ok=True, extra=None, confirmation=None):
        command = ['bash', str(manager)] + args
        environment = dict(env, **(extra or {}))
        if confirmation is None:
            result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=15)
            code, output = result.returncode, result.stdout + result.stderr
        else:
            # Give /dev/tty a real controlling terminal, as on an SSH session.
            pid, fd = pty.fork()
            if pid == 0:
                os.execvpe('bash', command, environment)
            chunks, deadline = [], time.monotonic() + 15
            os.write(fd, (confirmation + '\n').encode())
            while time.monotonic() < deadline:
                if select.select([fd], [], [], 0.1)[0]:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    chunks.append(chunk)
            else:
                os.kill(pid, 9)
            _, status = os.waitpid(pid, 0)
            os.close(fd)
            code = os.waitstatus_to_exitcode(status)
            output = b''.join(chunks).decode(errors='replace')
        assert (code == 0) == ok, (args, code, output)
        return output

    def passed_test(name):
        global passed
        passed += 1
        print('PASS:', name)

    assert '1.2.0' in run(['version'])
    assert 'SECRET_TEST_VALUE' not in run(['status'])
    passed_test('version and status hide token')
    run(['disable'])
    assert not (root / 'timer').exists()
    assert manager.exists() and config.exists()
    run(['enable'])
    assert (root / 'timer').exists()
    passed_test('enable and disable preserve installed files')
    valid = backups / 'test.sql.gz'
    data = b'-- PostgreSQL database dump\nCREATE TABLE users(id integer);\n-- PostgreSQL database dump complete\n'
    valid.write_bytes(gzip.compress(data))
    meta = Path(str(valid) + '.meta')
    meta.write_text('sha256=' + hashlib.sha256(valid.read_bytes()).hexdigest() + '\n')
    run(['verify', str(valid)])
    assert str(valid) in run(['list'])
    passed_test('verify and list valid backup')
    meta.write_text('sha256=' + '0' * 64 + '\n')
    run(['verify', str(valid)], ok=False)
    meta.unlink()
    broken = backups / 'broken.sql.gz'
    broken.write_bytes(b'broken')
    run(['verify', str(broken)], ok=False)
    broken.write_bytes(gzip.compress(b'-- incomplete dump'))
    run(['verify', str(broken)], ok=False)
    passed_test('reject corrupt, incomplete and hash-mismatched backups')
    run(['restore', str(valid), 'IBSng'], ok=False)
    run(['restore', str(valid), 'existing'], ok=False, extra={'DB_EXISTS': '1'})
    assert 'createdb' not in (root / 'docker.log').read_text()
    passed_test('restore refuses configured and existing databases')
    run(['restore', str(valid), 'restored'], ok=False, confirmation='NO')
    assert not (root / 'worker.log').exists()
    passed_test('cancelled restore makes no backup or database')
    run(['restore', str(valid), 'restored'], confirmation='RESTORE restored')
    assert '--local' in (root / 'worker.log').read_text()
    assert (root / 'import.sql').read_bytes() == data
    assert 'IBSNG_DB=IBSng' in config.read_text()
    passed_test('confirmed restore makes safety backup and imports only to new database')
    before = (root / 'docker.log').read_text().count('createdb')
    run(['restore', str(valid), 'failed_safety'], ok=False, extra={'WORKER_FAIL': '5'}, confirmation='RESTORE failed_safety')
    assert (root / 'docker.log').read_text().count('createdb') == before
    passed_test('safety backup failure prevents database creation')
    output = run(['restore', str(valid), 'failed_import'], ok=False, extra={'IMPORT_FAIL': '1'}, confirmation='RESTORE failed_import')
    assert 'retained for inspection' in output
    assert 'IBSNG_DB=IBSng' in config.read_text()
    passed_test('failed import leaves original configuration intact')
    run(['uninstall'], ok=False, extra={'ACTIVE_STATE': 'activating'})
    assert manager.exists()
    run(['uninstall'], ok=False, confirmation='NO')
    assert manager.exists() and not list(snapshots.iterdir())
    passed_test('uninstall refuses active backup and requires exact confirmation')
    with open(root / 'lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        run(['uninstall'], ok=False, confirmation='UNINSTALL')
    assert manager.exists()
    passed_test('uninstall refuses an active maintenance lock')
    prior_config, prior_backup = config.read_bytes(), valid.read_bytes()
    run(['uninstall'], confirmation='UNINSTALL')
    assert not manager.exists() and not worker.exists() and not offline.exists()
    assert not list(units.iterdir()) and not (root / 'timer').exists()
    assert config.read_bytes() == prior_config and valid.read_bytes() == prior_backup
    assert len(list(snapshots.iterdir())) == 1
    assert any(p.name == 'config.env' for p in snapshots.rglob('*'))
    passed_test('uninstall removes tools, saves snapshot and keeps config and backups')
    print(f'All {passed} management tests passed.')
