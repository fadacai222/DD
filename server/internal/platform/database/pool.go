package database

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func Open(ctx context.Context, databaseURL string, observers ...Observer) (*pgxpool.Pool, error) {
	if strings.TrimSpace(databaseURL) == "" {
		return nil, errors.New("database URL is required")
	}
	config, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, errors.New("invalid PostgreSQL connection configuration")
	}
	config.MaxConns = 20
	config.MinConns = 0
	config.MaxConnLifetime = 30 * time.Minute
	config.MaxConnIdleTime = 5 * time.Minute
	config.HealthCheckPeriod = 30 * time.Second
	if len(observers) > 0 && observers[0] != nil {
		config.ConnConfig.Tracer = queryTracer{observer: observers[0]}
	}

	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		return nil, errors.New("create PostgreSQL pool")
	}
	pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("PostgreSQL readiness check failed: %w", redactError(err))
	}
	return pool, nil
}

func Ping(ctx context.Context, pool *pgxpool.Pool) error {
	if pool == nil {
		return errors.New("PostgreSQL pool is not configured")
	}
	return pool.Ping(ctx)
}

func redactError(err error) error {
	message := err.Error()
	for _, marker := range []string{"postgres://", "postgresql://"} {
		if strings.Contains(message, marker) {
			return errors.New("connection string redacted")
		}
	}
	if len(message) > 300 {
		message = message[:300] + "…"
	}
	return errors.New(message)
}
