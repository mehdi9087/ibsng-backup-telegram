# Validation

- Shell syntax validation passed for the installer, worker and manager.
- Eighteen installer/worker integration tests and thirteen management tests passed on Linux.
- All automated tests use temporary paths and mocked Docker, systemd and Telegram commands. They do not change an installed service or send Telegram messages.
- Coverage includes delivery failures, retention, local-only backups, automatic detection, installation rollback, offline scheduling, disabled-state preservation, embedded source consistency, integrity verification, restore confirmation and safeguards, maintenance locks, and uninstall with removal of active/archived settings and local backup files while preserving unrelated files and the live database; unsafe backup-directory rejection.
- Confirmation tests use a real pseudo-terminal. Database creation and SQL import are mocked; this is not proof of a full real-world database recovery.
- The installer normally checks backup delivery during installation. The manager update command skips delivery tests and preserves the existing timer state.
