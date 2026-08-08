package realtimebus

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/protocol"
	"github.com/redis/go-redis/v9"
)

func TestRedisBusCrossNodeDeliveryAndPubSubReconnect(t *testing.T) {
	rawURL := strings.TrimSpace(os.Getenv("DD_REALTIME_TEST_REDIS_URL"))
	if rawURL == "" {
		t.Skip("DD_REALTIME_TEST_REDIS_URL is not set")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	nodeA, err := NewRedisBus(ctx, rawURL, "integration-node-a")
	if err != nil {
		t.Fatal(err)
	}
	defer nodeA.Close()
	nodeB, err := NewRedisBus(ctx, rawURL, "integration-node-b")
	if err != nil {
		t.Fatal(err)
	}
	defer nodeB.Close()

	reasons := make(chan string, 32)
	subscribeContext, stopSubscribe := context.WithCancel(ctx)
	defer stopSubscribe()
	go func() {
		_ = nodeB.Subscribe(subscribeContext, func(userID string, envelope protocol.OutboundEnvelope) {
			if userID != "user-integration-1" || envelope.Type != protocol.TypeEventAvailable {
				return
			}
			payload, ok := envelope.Payload.(map[string]any)
			if !ok {
				return
			}
			reason, _ := payload["reason"].(string)
			if reason != "" {
				select {
				case reasons <- reason:
				default:
				}
			}
		})
	}()

	publishUntilReason(t, ctx, nodeA, reasons, "before-reconnect")

	options, err := redis.ParseURL(rawURL)
	if err != nil {
		t.Fatal(err)
	}
	admin := redis.NewClient(options)
	defer admin.Close()
	if err := admin.ClientKillByFilter(ctx, "TYPE", "pubsub", "SKIPME", "no").Err(); err != nil {
		t.Fatalf("kill pubsub connections: %v", err)
	}

	// go-redis PubSub reconnects after its connection is killed. A durable Sync
	// endpoint remains authoritative, so the Redis layer only needs to recover
	// future wake-up hints rather than replay hints lost during the outage.
	publishUntilReason(t, ctx, nodeA, reasons, "after-reconnect")
}

func publishUntilReason(t *testing.T, ctx context.Context, publisher *RedisBus, reasons <-chan string, expected string) {
	t.Helper()
	deadline := time.NewTimer(8 * time.Second)
	defer deadline.Stop()
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			t.Fatalf("context ended waiting for %q: %v", expected, ctx.Err())
		case <-deadline.C:
			t.Fatalf("timed out waiting for cross-node reason %q", expected)
		case reason := <-reasons:
			if reason == expected {
				return
			}
		case <-ticker.C:
			err := publisher.Publish(ctx, "user-integration-1", protocol.OutboundEnvelope{
				Type:    protocol.TypeEventAvailable,
				EventID: 999,
				Payload: protocol.EventAvailablePayload{Reason: expected},
			})
			if err != nil {
				continue
			}
		}
	}
}
