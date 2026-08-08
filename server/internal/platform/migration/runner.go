package migration

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

const migrationAdvisoryLockKey int64 = 4444456476971547

type AppliedMigration struct {
	Version   int64
	Name      string
	Checksum  string
	AppliedAt time.Time
}

type StatusRow struct {
	Version  int64
	Name     string
	Applied  bool
	Checksum string
}

func EnsureMetadata(ctx context.Context, connection *pgx.Conn) error {
	_, err := connection.Exec(ctx, `
CREATE TABLE IF NOT EXISTS schema_migrations (
    version bigint PRIMARY KEY,
    name text NOT NULL,
    checksum char(64) NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now()
)`)
	if err != nil {
		return fmt.Errorf("create schema_migrations: %w", err)
	}
	return nil
}

func Up(ctx context.Context, connection *pgx.Conn, migrations []Migration) (int, error) {
	if err := EnsureMetadata(ctx, connection); err != nil {
		return 0, err
	}
	if err := lock(ctx, connection); err != nil {
		return 0, err
	}
	defer unlock(connection)

	applied, err := listApplied(ctx, connection)
	if err != nil {
		return 0, err
	}
	pending, err := planPending(migrations, applied)
	if err != nil {
		return 0, err
	}

	count := 0
	for _, migration := range pending {
		if err := applyOne(ctx, connection, migration); err != nil {
			return count, err
		}
		count++
	}
	return count, nil
}

func applyOne(ctx context.Context, connection *pgx.Conn, migration Migration) (err error) {
	tx, err := connection.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin migration %06d: %w", migration.Version, err)
	}
	defer func() {
		if err != nil {
			_ = tx.Rollback(context.Background())
		}
	}()

	if _, err = tx.Exec(ctx, migration.UpSQL); err != nil {
		return fmt.Errorf("apply migration %06d_%s: %w", migration.Version, migration.Name, err)
	}
	if _, err = tx.Exec(ctx,
		`INSERT INTO schema_migrations(version, name, checksum) VALUES ($1, $2, $3)`,
		migration.Version, migration.Name, migration.Checksum,
	); err != nil {
		return fmt.Errorf("record migration %06d_%s: %w", migration.Version, migration.Name, err)
	}
	if err = tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit migration %06d_%s: %w", migration.Version, migration.Name, err)
	}
	return nil
}

func DownOne(ctx context.Context, connection *pgx.Conn, migrations []Migration) (bool, error) {
	if err := EnsureMetadata(ctx, connection); err != nil {
		return false, err
	}
	if err := lock(ctx, connection); err != nil {
		return false, err
	}
	defer unlock(connection)

	applied, err := listApplied(ctx, connection)
	if err != nil {
		return false, err
	}
	if _, err := planPending(migrations, applied); err != nil {
		return false, err
	}
	if len(applied) == 0 {
		return false, nil
	}
	sort.Slice(applied, func(i, j int) bool { return applied[i].Version > applied[j].Version })
	latest := applied[0]

	var target *Migration
	for index := range migrations {
		if migrations[index].Version == latest.Version {
			target = &migrations[index]
			break
		}
	}
	if target == nil {
		return false, fmt.Errorf("applied migration %06d is not present in this build", latest.Version)
	}

	tx, err := connection.Begin(ctx)
	if err != nil {
		return false, fmt.Errorf("begin rollback %06d: %w", target.Version, err)
	}
	if _, err := tx.Exec(ctx, target.DownSQL); err != nil {
		_ = tx.Rollback(ctx)
		return false, fmt.Errorf("rollback migration %06d_%s: %w", target.Version, target.Name, err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM schema_migrations WHERE version = $1`, target.Version); err != nil {
		_ = tx.Rollback(ctx)
		return false, fmt.Errorf("remove migration record %06d_%s: %w", target.Version, target.Name, err)
	}
	if err := tx.Commit(ctx); err != nil {
		return false, fmt.Errorf("commit rollback %06d_%s: %w", target.Version, target.Name, err)
	}
	return true, nil
}

func Status(ctx context.Context, connection *pgx.Conn, migrations []Migration) ([]StatusRow, error) {
	if err := EnsureMetadata(ctx, connection); err != nil {
		return nil, err
	}
	applied, err := listApplied(ctx, connection)
	if err != nil {
		return nil, err
	}
	if _, err := planPending(migrations, applied); err != nil {
		return nil, err
	}
	appliedVersions := make(map[int64]AppliedMigration, len(applied))
	for _, item := range applied {
		appliedVersions[item.Version] = item
	}
	rows := make([]StatusRow, 0, len(migrations))
	for _, migration := range migrations {
		_, ok := appliedVersions[migration.Version]
		rows = append(rows, StatusRow{
			Version:  migration.Version,
			Name:     migration.Name,
			Applied:  ok,
			Checksum: migration.Checksum,
		})
	}
	return rows, nil
}

func listApplied(ctx context.Context, connection *pgx.Conn) ([]AppliedMigration, error) {
	rows, err := connection.Query(ctx, `SELECT version, name, trim(checksum), applied_at FROM schema_migrations ORDER BY version`)
	if err != nil {
		return nil, fmt.Errorf("query schema_migrations: %w", err)
	}
	defer rows.Close()

	result := make([]AppliedMigration, 0)
	for rows.Next() {
		var item AppliedMigration
		if err := rows.Scan(&item.Version, &item.Name, &item.Checksum, &item.AppliedAt); err != nil {
			return nil, fmt.Errorf("scan schema_migrations: %w", err)
		}
		result = append(result, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate schema_migrations: %w", err)
	}
	return result, nil
}

func planPending(migrations []Migration, applied []AppliedMigration) ([]Migration, error) {
	available := make(map[int64]Migration, len(migrations))
	for _, migration := range migrations {
		available[migration.Version] = migration
	}
	appliedVersions := make(map[int64]struct{}, len(applied))
	for _, item := range applied {
		migration, ok := available[item.Version]
		if !ok {
			return nil, fmt.Errorf("applied migration %06d_%s is not present in this build", item.Version, item.Name)
		}
		if migration.Name != item.Name {
			return nil, fmt.Errorf("applied migration %06d name mismatch: database=%q build=%q", item.Version, item.Name, migration.Name)
		}
		if migration.Checksum != item.Checksum {
			return nil, fmt.Errorf("applied migration %06d_%s checksum mismatch", item.Version, item.Name)
		}
		appliedVersions[item.Version] = struct{}{}
	}

	pending := make([]Migration, 0)
	for _, migration := range migrations {
		if _, ok := appliedVersions[migration.Version]; !ok {
			pending = append(pending, migration)
		}
	}
	sort.Slice(pending, func(i, j int) bool { return pending[i].Version < pending[j].Version })
	return pending, nil
}

func lock(ctx context.Context, connection *pgx.Conn) error {
	var locked bool
	if err := connection.QueryRow(ctx, `SELECT pg_try_advisory_lock($1)`, migrationAdvisoryLockKey).Scan(&locked); err != nil {
		return fmt.Errorf("acquire migration advisory lock: %w", err)
	}
	if !locked {
		return errors.New("another migration process already holds the migration lock")
	}
	return nil
}

func unlock(connection *pgx.Conn) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_, _ = connection.Exec(ctx, `SELECT pg_advisory_unlock($1)`, migrationAdvisoryLockKey)
}
