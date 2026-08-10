package migrations_test

import (
	"testing"

	"example.com/selfhosted-im/server/internal/platform/migration"
	"example.com/selfhosted-im/server/migrations"
)

func TestEmbeddedMigrationsAreCompletePairs(t *testing.T) {
	loaded, err := migration.Load(migrations.Files)
	if err != nil {
		t.Fatalf("load embedded migrations: %v", err)
	}
	if len(loaded) == 0 {
		t.Fatal("expected at least one embedded migration")
	}
}
