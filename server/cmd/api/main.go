package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"example.com/selfhosted-im/server/internal/httpapi"
)

const defaultPort = 18473

var version = "dev"

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	port := readPort(logger)
	allowedOrigins := splitNonEmpty(os.Getenv("IM_ALLOWED_ORIGINS"))

	server := &http.Server{
		Addr: ":" + strconv.Itoa(port),
		Handler: httpapi.NewHandler(httpapi.Config{
			Version:        version,
			AllowedOrigins: allowedOrigins,
		}),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 * 1024,
	}

	shutdownContext, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	errorChannel := make(chan error, 1)
	go func() {
		logger.Info("realtime poc listening", "address", server.Addr, "version", version)
		errorChannel <- server.ListenAndServe()
	}()

	select {
	case err := <-errorChannel:
		if !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server stopped unexpectedly", "error", err)
			os.Exit(1)
		}
	case <-shutdownContext.Done():
		logger.Info("shutdown requested")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		logger.Error("graceful shutdown failed", "error", err)
		os.Exit(1)
	}

	logger.Info("server stopped")
}

func readPort(logger *slog.Logger) int {
	raw := strings.TrimSpace(os.Getenv("IM_PORT"))
	if raw == "" {
		return defaultPort
	}

	port, err := strconv.Atoi(raw)
	if err != nil || port < 10000 || port > 65535 {
		logger.Error("IM_PORT must be a number between 10000 and 65535", "value", raw)
		os.Exit(2)
	}
	return port
}

func splitNonEmpty(raw string) []string {
	parts := strings.Split(raw, ",")
	values := make([]string, 0, len(parts))
	for _, part := range parts {
		value := strings.TrimSpace(part)
		if value != "" {
			values = append(values, value)
		}
	}
	return values
}
