# Validation

- Shell syntax and read-only installer preflight passed on Ubuntu 24.04.
- The new backup worker produced a valid compressed SQL dump from PostgreSQL 8.4.20 in an existing IBSng container. The dump included PostgreSQL's completion marker.
- The existing production service and timer definitions were unchanged.
- No Telegram message was sent during development. Telegram responses were mocked for integration tests; installation normally performs the real delivery check.
- Nine isolated Linux integration tests passed: delivery success, partial dump failure, API `ok:false`, HTTP error, network error, malformed JSON, fresh installation permissions, reinstall preservation, and rollback after a failed initial backup.
- Database restore was not performed. Other Linux distributions and native/non-Docker IBSng installations were not validated.
