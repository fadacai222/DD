package httpapi

import (
	"context"
	"fmt"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/google/uuid"
)

func TestFormalRealtimeLoad200AuthenticatedConnections(t *testing.T) {
	if strings.TrimSpace(os.Getenv("DD_RUN_P4_LOAD")) != "1" {
		t.Skip("DD_RUN_P4_LOAD=1 is required")
	}

	auth := &loadPrincipalAuthService{}
	server := httptest.NewServer(NewHandler(Config{Version: "p4-load", AuthService: auth}))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/api/v1/realtime"

	const connectionCount = 200
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	connections := make([]*websocket.Conn, connectionCount)
	errorsCh := make(chan error, connectionCount)
	startGate := make(chan struct{})
	var wg sync.WaitGroup
	started := time.Now()

	for index := 0; index < connectionCount; index++ {
		index := index
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-startGate
			userIndex := index / 10 // ten sockets per account, below the 16/account safety limit.
			token := fmt.Sprintf("load-user-%03d-connection-%03d", userIndex, index)
			connection, _, err := websocket.Dial(ctx, wsURL, nil)
			if err != nil {
				errorsCh <- fmt.Errorf("dial %d: %w", index, err)
				return
			}
			if err := wsjson.Write(ctx, connection, map[string]any{
				"type":      "hello",
				"requestId": fmt.Sprintf("hello-%03d", index),
				"payload": map[string]any{
					"clientId":        fmt.Sprintf("load-client-%03d", index),
					"accessToken":     token,
					"protocolVersion": "1",
					"lastEventId":     0,
				},
			}); err != nil {
				connection.CloseNow()
				errorsCh <- fmt.Errorf("hello write %d: %w", index, err)
				return
			}
			var ack struct {
				Type string `json:"type"`
			}
			if err := wsjson.Read(ctx, connection, &ack); err != nil || ack.Type != "hello_ack" {
				connection.CloseNow()
				errorsCh <- fmt.Errorf("hello ack %d: type=%s err=%v", index, ack.Type, err)
				return
			}
			var ready struct {
				Type string `json:"type"`
			}
			if err := wsjson.Read(ctx, connection, &ready); err != nil || ready.Type != "server_ready" {
				connection.CloseNow()
				errorsCh <- fmt.Errorf("server ready %d: type=%s err=%v", index, ready.Type, err)
				return
			}
			connections[index] = connection
		}()
	}
	close(startGate)
	wg.Wait()
	close(errorsCh)
	for connectionErr := range errorsCh {
		if connectionErr != nil {
			for _, connection := range connections {
				if connection != nil {
					connection.CloseNow()
				}
			}
			t.Fatal(connectionErr)
		}
	}
	connectDuration := time.Since(started)
	defer func() {
		for _, connection := range connections {
			if connection != nil {
				connection.CloseNow()
			}
		}
	}()

	for index, connection := range connections {
		if connection == nil {
			t.Fatalf("connection %d was not retained", index)
		}
	}

	// Prove the sockets are not merely accepted but still responsive after all
	// 200 have become concurrently online.
	errorsCh = make(chan error, connectionCount)
	for index, connection := range connections {
		index, connection := index, connection
		wg.Add(1)
		go func() {
			defer wg.Done()
			requestID := fmt.Sprintf("ping-%03d", index)
			if err := wsjson.Write(ctx, connection, map[string]any{
				"type":      "ping",
				"requestId": requestID,
			}); err != nil {
				errorsCh <- fmt.Errorf("ping write %d: %w", index, err)
				return
			}
			var pong struct {
				Type      string `json:"type"`
				RequestID string `json:"requestId"`
			}
			if err := wsjson.Read(ctx, connection, &pong); err != nil {
				errorsCh <- fmt.Errorf("pong read %d: %w", index, err)
				return
			}
			if pong.Type != "pong" || pong.RequestID != requestID {
				errorsCh <- fmt.Errorf("pong %d type=%s requestId=%s", index, pong.Type, pong.RequestID)
			}
		}()
	}
	wg.Wait()
	close(errorsCh)
	for pingErr := range errorsCh {
		if pingErr != nil {
			t.Fatal(pingErr)
		}
	}

	t.Logf("P4 realtime load baseline: connections=%d connectDuration=%s allPongs=true", connectionCount, connectDuration)
}

type loadPrincipalAuthService struct {
	fakeAuthService
}

func (service *loadPrincipalAuthService) AuthenticateAccessToken(_ context.Context, raw string) (account.Principal, error) {
	var userIndex, connectionIndex int
	if _, err := fmt.Sscanf(raw, "load-user-%03d-connection-%03d", &userIndex, &connectionIndex); err != nil {
		return account.Principal{}, fmt.Errorf("invalid load access token")
	}
	return account.Principal{
		UserID:   uuid.NewSHA1(uuid.NameSpaceOID, []byte(fmt.Sprintf("load-user-%d", userIndex))),
		DeviceID: uuid.NewSHA1(uuid.NameSpaceOID, []byte(fmt.Sprintf("load-device-%d", connectionIndex))),
	}, nil
}
