package httpapi

import (
	"context"
	"sync"

	"example.com/selfhosted-im/server/internal/protocol"
	"github.com/coder/websocket"
)

type socketClient struct {
	connection *websocket.Conn
}

var socketWriteLocks sync.Map

func socketWriteLock(connection *websocket.Conn) *sync.Mutex {
	lock, _ := socketWriteLocks.LoadOrStore(connection, &sync.Mutex{})
	return lock.(*sync.Mutex)
}

func forgetSocketWriteLock(connection *websocket.Conn) {
	socketWriteLocks.Delete(connection)
}

func (client *socketClient) write(parent context.Context, message protocol.OutboundEnvelope) error {
	return writeSocket(parent, client.connection, message)
}

type socketHub struct {
	mu      sync.RWMutex
	clients map[string]map[*socketClient]struct{}
}

func newSocketHub() *socketHub {
	return &socketHub{clients: make(map[string]map[*socketClient]struct{})}
}

func (hub *socketHub) register(identity string, client *socketClient) {
	_ = hub.tryRegister(identity, client, 0)
}

func (hub *socketHub) tryRegister(identity string, client *socketClient, maximum int) bool {
	hub.mu.Lock()
	defer hub.mu.Unlock()

	connections := hub.clients[identity]
	if maximum > 0 && len(connections) >= maximum {
		return false
	}
	if connections == nil {
		connections = make(map[*socketClient]struct{})
		hub.clients[identity] = connections
	}
	connections[client] = struct{}{}
	return true
}

func (hub *socketHub) unregister(identity string, client *socketClient) {
	hub.mu.Lock()
	defer hub.mu.Unlock()

	connections := hub.clients[identity]
	delete(connections, client)
	if len(connections) == 0 {
		delete(hub.clients, identity)
	}
}

func (hub *socketHub) publish(identity string, message protocol.OutboundEnvelope) {
	hub.mu.RLock()
	connections := make([]*socketClient, 0, len(hub.clients[identity]))
	for client := range hub.clients[identity] {
		connections = append(connections, client)
	}
	hub.mu.RUnlock()

	for _, client := range connections {
		if err := client.write(context.Background(), message); err != nil {
			hub.unregister(identity, client)
		}
	}
}
