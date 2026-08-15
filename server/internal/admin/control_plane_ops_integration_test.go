package admin

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func openControlPlaneTestPool(t *testing.T) (*pgxpool.Pool, context.Context, context.CancelFunc) {
	t.Helper()
	databaseURL := strings.TrimSpace(os.Getenv("DD_ADMIN_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("DD_ADMIN_TEST_DATABASE_URL is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		cancel()
		t.Fatal(err)
	}
	return pool, ctx, cancel
}

func TestPushSnapshotWithFreshPostgres(t *testing.T) {
	pool, ctx, cancel := openControlPlaneTestPool(t)
	defer cancel()
	defer pool.Close()

	service := &Service{pool: pool, now: time.Now}
	snapshot, err := service.PushSnapshot(ctx, Principal{})
	if err != nil {
		t.Fatalf("PushSnapshot() error = %v", err)
	}
	if snapshot.PendingJobs != 0 || snapshot.RetryingJobs != 0 || snapshot.SentJobs24h != 0 || snapshot.DroppedJobs24h != 0 {
		t.Fatalf("unexpected push queue snapshot: %#v", snapshot)
	}
	if snapshot.OldestPendingAt != nil {
		t.Fatalf("oldest pending job should be nil on an empty queue: %v", snapshot.OldestPendingAt)
	}
}

func TestRTCSnapshotWithFreshPostgres(t *testing.T) {
	pool, ctx, cancel := openControlPlaneTestPool(t)
	defer cancel()
	defer pool.Close()

	service := &Service{pool: pool, now: time.Now}
	snapshot, err := service.RTCSnapshot(ctx, Principal{})
	if err != nil {
		t.Fatalf("RTCSnapshot() error = %v", err)
	}
	if snapshot.DirectCallsToday != 0 || snapshot.ActiveDirectCalls != 0 || snapshot.AcceptedDirectCalls24h != 0 || snapshot.GroupCallsToday != 0 || snapshot.ActiveGroupCalls != 0 || snapshot.ActiveGroupParticipants != 0 {
		t.Fatalf("unexpected RTC snapshot: %#v", snapshot)
	}
}
