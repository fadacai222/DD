# Runtime backups

Backup sets are written here by default and are ignored by Git. A backup is not considered usable until `verify-backup.sh` passes.

For real production, place `DD_BACKUP_ROOT` on encrypted storage that is independent from the application data disk and copy verified backup sets off-host according to your DR policy.
