package database

import (
	"context"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

type Observer interface {
	ObservePostgresQuery(operation string, duration time.Duration, err error)
}

type queryTraceKey struct{}

type queryTrace struct {
	started   time.Time
	operation string
}

type queryTracer struct {
	observer Observer
}

func (tracer queryTracer) TraceQueryStart(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryStartData) context.Context {
	return context.WithValue(ctx, queryTraceKey{}, queryTrace{
		started:   time.Now(),
		operation: sqlOperation(data.SQL),
	})
}

func (tracer queryTracer) TraceQueryEnd(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryEndData) {
	trace, ok := ctx.Value(queryTraceKey{}).(queryTrace)
	if !ok || tracer.observer == nil {
		return
	}
	tracer.observer.ObservePostgresQuery(trace.operation, time.Since(trace.started), data.Err)
}

func sqlOperation(sql string) string {
	fields := strings.Fields(sql)
	if len(fields) == 0 {
		return "OTHER"
	}
	switch operation := strings.ToUpper(fields[0]); operation {
	case "SELECT", "INSERT", "UPDATE", "DELETE", "BEGIN", "COMMIT", "ROLLBACK", "COPY":
		return operation
	default:
		return "OTHER"
	}
}
