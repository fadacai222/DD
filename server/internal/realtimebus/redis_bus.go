package realtimebus

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"example.com/selfhosted-im/server/internal/protocol"
	"github.com/redis/go-redis/v9"
)

const defaultChannel = "dd:realtime:user-events:v1"

var ErrUnavailable = errors.New("realtime event bus unavailable")

type Observer interface {
	ObserveRedis(operation string, duration time.Duration, err error)
}

type RedisBus struct {
	client   *redis.Client
	nodeID   string
	channel  string
	observer Observer
}

type redisDelivery struct {
	OriginNodeID string                    `json:"originNodeId"`
	UserID       string                    `json:"userId"`
	Envelope     protocol.OutboundEnvelope `json:"envelope"`
}

func NewRedisBus(ctx context.Context, rawURL, nodeID string, observers ...Observer) (*RedisBus, error) {
	rawURL = strings.TrimSpace(rawURL)
	nodeID = strings.TrimSpace(nodeID)
	if rawURL == "" || nodeID == "" {
		return nil, ErrUnavailable
	}
	options, err := redis.ParseURL(rawURL)
	if err != nil {
		return nil, fmt.Errorf("parse redis url: %w", err)
	}
	client := redis.NewClient(options)
	var observer Observer
	if len(observers) > 0 {
		observer = observers[0]
	}
	started := time.Now()
	if err := client.Ping(ctx).Err(); err != nil {
		if observer != nil {
			observer.ObserveRedis("connect", time.Since(started), err)
		}
		_ = client.Close()
		return nil, fmt.Errorf("ping redis: %w", err)
	}
	if observer != nil {
		observer.ObserveRedis("connect", time.Since(started), nil)
	}
	return &RedisBus{client: client, nodeID: nodeID, channel: defaultChannel, observer: observer}, nil
}

func (bus *RedisBus) Ping(ctx context.Context) error {
	if bus == nil || bus.client == nil {
		return ErrUnavailable
	}
	started := time.Now()
	err := bus.client.Ping(ctx).Err()
	if bus.observer != nil {
		bus.observer.ObserveRedis("ping", time.Since(started), err)
	}
	if err != nil {
		return fmt.Errorf("ping realtime redis: %w", err)
	}
	return nil
}

func (bus *RedisBus) Publish(ctx context.Context, userID string, envelope protocol.OutboundEnvelope) error {
	if bus == nil || bus.client == nil {
		return ErrUnavailable
	}
	userID = strings.TrimSpace(userID)
	if userID == "" || strings.TrimSpace(envelope.Type) == "" {
		return fmt.Errorf("publish realtime event: invalid delivery")
	}
	// Event IDs are local to one API process/connection. Receiving nodes assign
	// their own monotonic event ID before writing the frame to local sockets.
	envelope.EventID = 0
	encoded, err := json.Marshal(redisDelivery{
		OriginNodeID: bus.nodeID,
		UserID:       userID,
		Envelope:     envelope,
	})
	if err != nil {
		return fmt.Errorf("encode realtime event: %w", err)
	}
	started := time.Now()
	err = bus.client.Publish(ctx, bus.channel, encoded).Err()
	if bus.observer != nil {
		bus.observer.ObserveRedis("publish", time.Since(started), err)
	}
	if err != nil {
		return fmt.Errorf("publish realtime event: %w", err)
	}
	return nil
}

func (bus *RedisBus) Subscribe(ctx context.Context, deliver func(userID string, envelope protocol.OutboundEnvelope)) error {
	if bus == nil || bus.client == nil || deliver == nil {
		return ErrUnavailable
	}
	pubsub := bus.client.Subscribe(ctx, bus.channel)
	defer pubsub.Close()
	started := time.Now()
	if _, err := pubsub.Receive(ctx); err != nil {
		if bus.observer != nil {
			bus.observer.ObserveRedis("subscribe", time.Since(started), err)
		}
		return fmt.Errorf("subscribe realtime event bus: %w", err)
	}
	if bus.observer != nil {
		bus.observer.ObserveRedis("subscribe", time.Since(started), nil)
	}

	channel := pubsub.Channel()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case message, ok := <-channel:
			if !ok {
				return ErrUnavailable
			}
			var delivery redisDelivery
			if err := json.Unmarshal([]byte(message.Payload), &delivery); err != nil {
				continue
			}
			if strings.TrimSpace(delivery.OriginNodeID) == bus.nodeID {
				continue
			}
			if strings.TrimSpace(delivery.UserID) == "" || strings.TrimSpace(delivery.Envelope.Type) == "" {
				continue
			}
			deliver(delivery.UserID, delivery.Envelope)
		}
	}
}

func (bus *RedisBus) Close() error {
	if bus == nil || bus.client == nil {
		return nil
	}
	return bus.client.Close()
}
