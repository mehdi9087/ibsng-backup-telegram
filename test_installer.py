#!/usr/bin/env python3
"""Offline integration tests. Run on Linux: python3 test_installer.py.
Uses temporary directories and mock Docker/systemd/Telegram commands only.
"""
import gzip
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent


def write(path, text, mode=0o700):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(mode)


with tempfile.TemporaryDirectory(prefix="ibsng-tests-") as temporary:
    root = Path(temporary)
    mock = root / "mock"
    mock.mkdir()
    write(mock / "docker", '''#!/bin/bash
case "$1" in
  info) exit 0 ;;
  inspect) echo true ;;
  exec)
    if [[ "$5" == pg_dump ]]; then
      if [[ "${6:-}" == --version ]]; then echo 'pg_dump 8.4'; exit; fi
      echo '-- PostgreSQL database dump'
      [[ "${DUMP_FAIL:-0}" == 0 ]] || exit 9
      echo 'CREATE TABLE users (id integer);'
    elif [[ "${9:-}" == 'SELECT 1' ]]; then echo 1
    else printf 'users=1\\nras=1\\nadmins=1\\n'; fi ;;
esac
''')
    write(mock / "curl", '''#!/bin/bash
cat >/dev/null
while (($#)); do
  case "$1" in --output) response="$2"; shift ;; esac
  shift
done
printf '%s' "$API_JSON" > "$response"
printf '%s' "${API_STATUS:-200}"
exit "${CURL_FAIL:-0}"
''')
    env = dict(os.environ, PATH=str(mock) + ":" + os.environ["PATH"])
    passed = 0

    def run_worker(name, overrides=None, expect=0):
        global passed
        case = root / name
        case.mkdir()
        config = case / "config.env"
        write(config, f'''IBSNG_CONTAINER=ibsng
IBSNG_DB=IBSng
HOST_LABEL=test-host
BACKUP_DIR={case}/backups
LOCK_FILE={case}/lock
TELEGRAM_SEND=true
TELEGRAM_BOT_TOKEN=123:TEST_ONLY
TELEGRAM_CHAT_ID=123
RETENTION_HOURS=1
''')
        backups = case / "backups"
        backups.mkdir()
        unrelated = backups / "unrelated.sql.gz"
        unrelated.write_bytes(b"retain me")
        old = backups / "IBSng_test-host_20200101-000000.sql.gz"
        old.write_bytes(b"old own backup")
        for path in (unrelated, old):
            os.utime(path, (time.time()-10000, time.time()-10000))
        command_env = dict(env, CONFIG_FILE=str(config), API_JSON='{"ok":true}')
        command_env.update(overrides or {})
        result = subprocess.run(["bash", str(HERE / "backup.sh")], env=command_env, capture_output=True, text=True)
        assert result.returncode == expect, (name, result.stdout, result.stderr)
        assert unrelated.exists(), name
        assert old.exists() == (expect != 0), name
        dumps = [p for p in backups.glob("*.sql.gz") if p not in (old, unrelated)]
        if expect == 9:
            assert not dumps, name
        else:
            assert len(dumps) == 1, (name, dumps)
            data = gzip.decompress(dumps[0].read_bytes())
            assert b"CREATE TABLE" in data
            assert dumps[0].stat().st_mode & 0o777 == 0o600
            digest = hashlib.sha256(dumps[0].read_bytes()).hexdigest()
            assert digest in Path(str(dumps[0]) + ".meta").read_text()
        assert not list(backups.glob(".ibsng-dump.*"))
        assert not list(backups.glob(".telegram-response.*"))
        passed += 1
        print("PASS:", name)

    run_worker("delivery_success")
    run_worker("partial_dump_failure", {"DUMP_FAIL": "1"}, 9)
    run_worker("api_false", {"API_JSON": '{"ok":false}'}, 4)
    run_worker("http_error", {"API_STATUS": "500"}, 4)
    run_worker("network_error", {"CURL_FAIL": "28"}, 4)
    run_worker("invalid_json", {"API_JSON": 'not-json'}, 4)

    # Rewrite paths in a test-only copy to avoid touching the host installation.
    sandbox = root / "installation"
    (sandbox / "etc/systemd/system").mkdir(parents=True)
    (sandbox / "usr/local/sbin").mkdir(parents=True)
    (sandbox / "var/backups").mkdir(parents=True)
    installer = (HERE / "install.sh").read_text()
    for path in ("/etc/ibsng-backup-telegram.env", "/etc/systemd/system", "/usr/local/sbin/ibsng-backup-telegram", "/var/backups/ibsng-backup-installer-"):
        installer = installer.replace(path, str(sandbox) + path)
    installer = installer.replace('[[ -d /run/systemd/system ]]', '[[ -d /tmp ]]')
    installer = installer.replace('[[ "$EUID" -eq 0 ]]', 'true')
    write(root / "install-test.sh", installer)
    write(mock / "systemctl", '''#!/bin/bash
case "$1" in
  is-active|is-enabled) test -f "$TEST_STATE" ;;
  show) echo inactive ;;
  enable) touch "$TEST_STATE" ;;
  disable) rm -f "$TEST_STATE" ;;
  start) [[ "$2" != *.service || "${START_FAIL:-0}" == 0 ]] ;;
  *) exit 0 ;;
esac
''')
    installer_env = dict(env, TELEGRAM_SEND="false", BACKUP_DIR=str(sandbox / "backups"), TEST_STATE=str(root / "timer-enabled"))

    def install(extra=None, expect=0):
        result = subprocess.run(["bash", str(root / "install-test.sh"), "--non-interactive"], env=dict(installer_env, **(extra or {})), capture_output=True, text=True)
        assert (result.returncode == 0) == (expect == 0), (result.stdout, result.stderr)

    install()
    config = sandbox / "etc/ibsng-backup-telegram.env"
    timer = sandbox / "etc/systemd/system/ibsng-backup-telegram.timer"
    binary = sandbox / "usr/local/sbin/ibsng-backup-telegram"
    assert config.stat().st_mode & 0o777 == 0o600
    assert binary.stat().st_mode & 0o777 == 0o700
    print("PASS: fresh installation and file permissions")
    passed += 1
    timer.write_text(timer.read_text() + "# existing custom schedule marker\n")
    prior = {p: p.read_bytes() for p in (config, timer, binary)}
    install()
    assert all(p.read_bytes() == data for p, data in prior.items())
    print("PASS: reinstall preserves config and timer")
    passed += 1
    binary.write_text("#!/bin/bash\n# previous working version\n")
    prior = {p: p.read_bytes() for p in (config, timer, binary)}
    install({"START_FAIL": "1"}, expect=1)
    assert all(p.read_bytes() == data for p, data in prior.items())
    assert (root / "timer-enabled").exists()
    print("PASS: failed initial backup restores prior installation")
    passed += 1
    print(f"All {passed} integration tests passed.")
