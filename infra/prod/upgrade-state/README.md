# Upgrade evidence

`upgrade.sh` writes machine-readable evidence here. Each run records raw pre/post migration status, `evidence.env`, and `compatibility-row.json` with from/to release tags, from/to schema versions, rollback mode, and whether the previous application release accepts the newer database schema according to the migration checksum/status gate.

This directory is runtime state and is ignored by Git.
