# Validation

- Shell syntax validation passed.
- Automated tests use temporary directories and mocked Docker, systemd, and Telegram commands. They do not modify an installed service or send Telegram messages.
- Fourteen isolated Linux integration tests passed: delivery success, partial dump failure, API `ok:false`, HTTP error, network error, malformed JSON, fresh installation permissions, reinstall preservation, rollback, renamed target detection, schema validation, ambiguous target rejection, explicit selection, and maintenance database fallback.
- Real Telegram delivery and database restoration are outside the automated test suite. The installer normally checks delivery during installation.
