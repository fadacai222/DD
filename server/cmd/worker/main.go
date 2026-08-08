package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"example.com/selfhosted-im/server/internal/messaging"
	"example.com/selfhosted-im/server/internal/platform/appconfig"
	"example.com/selfhosted-im/server/internal/platform/database"
)

var version = "dev"

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	databaseURL, err := appconfig.ReadSecret("DATABASE_URL")
	if err != nil {
		logger.Error("worker database configuration failed", "error", err)
		os.Exit(2)
	}
	if databaseURL == "" {
		logger.Error("worker requires DATABASE_URL or DATABASE_URL_FILE")
		os.Exit(2)
	}

	startupContext, cancel := context.WithTimeout(ctx, 10*time.Second)
	pool, err := database.Open(startupContext, databaseURL)
	cancel()
	if err != nil {
		logger.Error("worker database startup failed", "error", err)
		os.Exit(1)
	}
	defer pool.Close()

	messagingService, err := messaging.NewService(messaging.Config{Pool: pool})
	if err != nil {
		logger.Error("worker messaging initialization failed", "error", err)
		os.Exit(2)
	}

	logger.Info("worker started", "service", "dd-worker", "version", version)
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			logger.Info("worker stopped", "service", "dd-worker", "version", version)
			return
		case <-ticker.C:
			batchContext, batchCancel := context.WithTimeout(ctx, 5*time.Second)
			processed, dispatchErr := messagingService.DispatchOutbox(batchContext, 100)
			batchCancel()
			if dispatchErr != nil {
				logger.Error("outbox dispatch failed", "service", "dd-worker", "error", dispatchErr)
				continue
			}
			if processed > 0 {
				logger.Info("outbox batch dispatched", "service", "dd-worker", "events", processed)
			}
		}
	}
}
