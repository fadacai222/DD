package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"time"

	"example.com/selfhosted-im/server/internal/platform/appconfig"
	"example.com/selfhosted-im/server/internal/platform/migration"
	"example.com/selfhosted-im/server/migrations"
	"github.com/jackc/pgx/v5"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	action := "up"
	if len(os.Args) > 1 {
		action = strings.ToLower(strings.TrimSpace(os.Args[1]))
	}
	if action != "up" && action != "down" && action != "status" {
		logger.Error("unsupported migration action", "action", action)
		os.Exit(2)
	}

	databaseURL, err := appconfig.ReadSecret("DATABASE_URL")
	if err != nil {
		logger.Error("invalid database configuration", "error", err)
		os.Exit(2)
	}
	if databaseURL == "" {
		logger.Error("DATABASE_URL or DATABASE_URL_FILE is required")
		os.Exit(2)
	}

	migrationSet, err := migration.Load(migrations.Files)
	if err != nil {
		logger.Error("load embedded migrations", "error", err)
		os.Exit(2)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	connection, err := pgx.Connect(ctx, databaseURL)
	if err != nil {
		logger.Error("connect to PostgreSQL", "error", sanitizeConnectionError(err))
		os.Exit(1)
	}
	defer connection.Close(context.Background())

	switch action {
	case "up":
		count, err := migration.Up(ctx, connection, migrationSet)
		if err != nil {
			logger.Error("migration up failed", "error", err)
			os.Exit(1)
		}
		logger.Info("migrations applied", "count", count)
	case "down":
		rolledBack, err := migration.DownOne(ctx, connection, migrationSet)
		if err != nil {
			logger.Error("migration rollback failed", "error", err)
			os.Exit(1)
		}
		logger.Info("migration rollback complete", "rolledBack", rolledBack)
	case "status":
		rows, err := migration.Status(ctx, connection, migrationSet)
		if err != nil {
			logger.Error("migration status failed", "error", err)
			os.Exit(1)
		}
		for _, row := range rows {
			state := "pending"
			if row.Applied {
				state = "applied"
			}
			fmt.Printf("%06d %-32s %s\n", row.Version, row.Name, state)
		}
	}
}

func sanitizeConnectionError(err error) string {
	message := err.Error()
	if index := strings.Index(message, "postgres://"); index >= 0 {
		return "PostgreSQL connection failed (connection string redacted)"
	}
	if index := strings.Index(message, "postgresql://"); index >= 0 {
		return "PostgreSQL connection failed (connection string redacted)"
	}
	if len(message) > 300 {
		return message[:300] + "…"
	}
	return message
}
