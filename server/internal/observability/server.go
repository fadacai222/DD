package observability

import (
	"context"
	"errors"
	"net"
	"net/http"
	"strings"
	"time"
)

type Server struct {
	httpServer *http.Server
	listener   net.Listener
}

func StartServer(address string, handler http.Handler) (*Server, error) {
	address = strings.TrimSpace(address)
	if address == "" {
		return nil, nil
	}
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return nil, err
	}
	httpServer := &http.Server{
		Addr:              address,
		Handler:           handler,
		ReadHeaderTimeout: 3 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       30 * time.Second,
		MaxHeaderBytes:    8 * 1024,
	}
	server := &Server{httpServer: httpServer, listener: listener}
	go func() {
		_ = httpServer.Serve(listener)
	}()
	return server, nil
}

func (server *Server) Shutdown(ctx context.Context) error {
	if server == nil || server.httpServer == nil {
		return nil
	}
	err := server.httpServer.Shutdown(ctx)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func (server *Server) Address() string {
	if server == nil || server.listener == nil {
		return ""
	}
	return server.listener.Addr().String()
}
