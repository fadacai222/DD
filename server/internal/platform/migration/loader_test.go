package migration

import (
	"testing"
	"testing/fstest"
)

func TestLoadSortsPairedMigrationsAndComputesChecksum(t *testing.T) {
	files := fstest.MapFS{
		"000002_second.up.sql":   {Data: []byte("CREATE TABLE second(id bigint);")},
		"000002_second.down.sql": {Data: []byte("DROP TABLE second;")},
		"000001_first.up.sql":    {Data: []byte("CREATE TABLE first(id bigint);")},
		"000001_first.down.sql":  {Data: []byte("DROP TABLE first;")},
	}

	migrations, err := Load(files)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if len(migrations) != 2 {
		t.Fatalf("len = %d, want 2", len(migrations))
	}
	if migrations[0].Version != 1 || migrations[0].Name != "first" {
		t.Fatalf("first migration = %#v", migrations[0])
	}
	if migrations[1].Version != 2 || migrations[1].Name != "second" {
		t.Fatalf("second migration = %#v", migrations[1])
	}
	if migrations[0].Checksum == "" || migrations[0].Checksum == migrations[1].Checksum {
		t.Fatalf("checksums must be non-empty and migration-specific")
	}
}

func TestLoadRejectsMissingPairAndDuplicateVersion(t *testing.T) {
	t.Run("missing down", func(t *testing.T) {
		_, err := Load(fstest.MapFS{
			"000001_first.up.sql": {Data: []byte("select 1;")},
		})
		if err == nil {
			t.Fatal("Load() unexpectedly succeeded")
		}
	})

	t.Run("duplicate version", func(t *testing.T) {
		_, err := Load(fstest.MapFS{
			"000001_first.up.sql":     {Data: []byte("select 1;")},
			"000001_first.down.sql":   {Data: []byte("select 1;")},
			"000001_another.up.sql":   {Data: []byte("select 2;")},
			"000001_another.down.sql": {Data: []byte("select 2;")},
		})
		if err == nil {
			t.Fatal("Load() unexpectedly succeeded")
		}
	})
}
