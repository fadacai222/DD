package migration

import (
	"strings"
	"testing"
)

func TestPlanPendingMigrations(t *testing.T) {
	migrations := []Migration{
		{Version: 1, Name: "first", Checksum: "aaa"},
		{Version: 2, Name: "second", Checksum: "bbb"},
		{Version: 3, Name: "third", Checksum: "ccc"},
	}

	pending, err := planPending(migrations, []AppliedMigration{{Version: 1, Name: "first", Checksum: "aaa"}})
	if err != nil {
		t.Fatalf("planPending() error = %v", err)
	}
	if len(pending) != 2 || pending[0].Version != 2 || pending[1].Version != 3 {
		t.Fatalf("pending = %#v", pending)
	}
}

func TestPlanPendingRejectsModifiedOrUnknownAppliedMigration(t *testing.T) {
	migrations := []Migration{{Version: 1, Name: "first", Checksum: "aaa"}}

	_, err := planPending(migrations, []AppliedMigration{{Version: 1, Name: "first", Checksum: "changed"}})
	if err == nil || !strings.Contains(err.Error(), "checksum") {
		t.Fatalf("checksum mismatch error = %v", err)
	}

	_, err = planPending(migrations, []AppliedMigration{{Version: 9, Name: "unknown", Checksum: "zzz"}})
	if err == nil || !strings.Contains(err.Error(), "not present") {
		t.Fatalf("unknown migration error = %v", err)
	}
}
