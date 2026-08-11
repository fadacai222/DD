package migrations_test

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/platform/migration"
	"example.com/selfhosted-im/server/migrations"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func TestFeatureMigrationRoundTripsWithPostgres(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("DD_MIGRATIONS_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("DD_MIGRATIONS_TEST_DATABASE_URL is not set")
	}

	all, err := migration.Load(migrations.Files)
	if err != nil {
		t.Fatalf("load migrations: %v", err)
	}

	tests := []struct {
		name    string
		version int64
		tables  []string
	}{
		{name: "QR000021", version: 21, tables: []string{"qr_login_sessions", "group_qr_invites"}},
		{name: "MomentActivity000028", version: 28, tables: []string{"moment_activity_notifications"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			connection := openIsolatedMigrationDatabase(t, databaseURL)
			defer connection.Close(context.Background())

			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			defer cancel()
			subset := migrationsThrough(t, all, test.version)

			applied, err := migration.Up(ctx, connection, subset)
			if err != nil {
				t.Fatalf("apply through migration %06d: %v", test.version, err)
			}
			if applied != len(subset) {
				t.Fatalf("applied migrations=%d want=%d", applied, len(subset))
			}
			assertMigrationApplied(t, ctx, connection, subset, test.version, true)
			assertTablesExist(t, ctx, connection, test.tables, true)

			applied, err = migration.Up(ctx, connection, subset)
			if err != nil {
				t.Fatalf("idempotent re-apply through migration %06d: %v", test.version, err)
			}
			if applied != 0 {
				t.Fatalf("idempotent re-apply count=%d want=0", applied)
			}

			rolledBack, err := migration.DownOne(ctx, connection, subset)
			if err != nil {
				t.Fatalf("rollback migration %06d: %v", test.version, err)
			}
			if !rolledBack {
				t.Fatalf("rollback migration %06d reported no migration", test.version)
			}
			assertMigrationApplied(t, ctx, connection, subset, test.version, false)
			assertTablesExist(t, ctx, connection, test.tables, false)

			applied, err = migration.Up(ctx, connection, subset)
			if err != nil {
				t.Fatalf("re-apply migration %06d after rollback: %v", test.version, err)
			}
			if applied != 1 {
				t.Fatalf("re-apply count=%d want=1", applied)
			}
			assertMigrationApplied(t, ctx, connection, subset, test.version, true)
			assertTablesExist(t, ctx, connection, test.tables, true)
		})
	}
}

func openIsolatedMigrationDatabase(t *testing.T, databaseURL string) *pgx.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	adminConfig, err := pgx.ParseConfig(databaseURL)
	if err != nil {
		t.Fatalf("parse migration test database URL: %v", err)
	}
	adminConfig.Database = "postgres"
	admin, err := pgx.ConnectConfig(ctx, adminConfig)
	if err != nil {
		t.Fatalf("connect postgres admin database: %v", err)
	}
	defer admin.Close(context.Background())

	databaseName := "dd_migration_test_" + strings.ReplaceAll(uuid.NewString(), "-", "")[:12]
	identifier := pgx.Identifier{databaseName}.Sanitize()
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+identifier); err != nil {
		t.Fatalf("create isolated migration database: %v", err)
	}
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cleanupCancel()
		cleanupConfig := *adminConfig
		cleanup, connectErr := pgx.ConnectConfig(cleanupCtx, &cleanupConfig)
		if connectErr != nil {
			t.Errorf("connect for migration database cleanup: %v", connectErr)
			return
		}
		defer cleanup.Close(context.Background())
		if _, dropErr := cleanup.Exec(cleanupCtx, "DROP DATABASE IF EXISTS "+identifier+" WITH (FORCE)"); dropErr != nil {
			t.Errorf("drop isolated migration database %s: %v", databaseName, dropErr)
		}
	})

	testConfig := *adminConfig
	testConfig.Database = databaseName
	connection, err := pgx.ConnectConfig(ctx, &testConfig)
	if err != nil {
		t.Fatalf("connect isolated migration database: %v", err)
	}
	return connection
}

func migrationsThrough(t *testing.T, all []migration.Migration, version int64) []migration.Migration {
	t.Helper()
	result := make([]migration.Migration, 0, len(all))
	for _, item := range all {
		if item.Version <= version {
			result = append(result, item)
		}
	}
	if len(result) == 0 || result[len(result)-1].Version != version {
		t.Fatalf("migration %06d not found", version)
	}
	return result
}

func assertMigrationApplied(t *testing.T, ctx context.Context, connection *pgx.Conn, migrations []migration.Migration, version int64, want bool) {
	t.Helper()
	rows, err := migration.Status(ctx, connection, migrations)
	if err != nil {
		t.Fatalf("migration status: %v", err)
	}
	for _, row := range rows {
		if row.Version == version {
			if row.Applied != want {
				t.Fatalf("migration %06d applied=%v want=%v", version, row.Applied, want)
			}
			return
		}
	}
	t.Fatalf("migration %06d missing from status", version)
}

func assertTablesExist(t *testing.T, ctx context.Context, connection *pgx.Conn, tables []string, want bool) {
	t.Helper()
	for _, table := range tables {
		var regclass *string
		if err := connection.QueryRow(ctx, `SELECT to_regclass($1)::text`, "public."+table).Scan(&regclass); err != nil {
			t.Fatalf("check table %s: %v", table, err)
		}
		got := regclass != nil
		if got != want {
			t.Fatalf("table %s exists=%v want=%v (%s)", table, got, want, fmt.Sprintf("public.%s", table))
		}
	}
}
