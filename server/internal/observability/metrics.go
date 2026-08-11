package observability

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const namespace = "dd"

type Metrics struct {
	registry *prometheus.Registry

	httpRequests             *prometheus.CounterVec
	httpDuration             *prometheus.HistogramVec
	httpActive               prometheus.Gauge
	dependencyUp             *prometheus.GaugeVec
	postgresQueries          *prometheus.CounterVec
	postgresDuration         *prometheus.HistogramVec
	postgresPool             *prometheus.GaugeVec
	redisOperations          *prometheus.CounterVec
	redisReconnects          prometheus.Counter
	websocketConnections     *prometheus.GaugeVec
	realtimeFailures         *prometheus.CounterVec
	realtimeQueueDropped     prometheus.Counter
	outboxBacklog            prometheus.Gauge
	outboxOldestSeconds      prometheus.Gauge
	pushJobs                 *prometheus.GaugeVec
	pushOldestSeconds        prometheus.Gauge
	pushRunning              prometheus.Gauge
	pushRetries              prometheus.Counter
	pushFailed               prometheus.Counter
	pushProviderRequests     *prometheus.CounterVec
	pushProviderDuration     *prometheus.HistogramVec
	pushProviderAuthFailures *prometheus.CounterVec
	pushProviderLastSuccess  *prometheus.GaugeVec
	pushProviderLastFailure  *prometheus.GaugeVec
	pushInvalidRatio         *prometheus.GaugeVec
	pushProviderConfigured   *prometheus.GaugeVec
	storageRequests          *prometheus.CounterVec
	storageDuration          *prometheus.HistogramVec
	smtpSends                *prometheus.CounterVec
	smtpDuration             prometheus.Histogram
	workerHeartbeat          prometheus.Gauge
	workerCycles             *prometheus.CounterVec
	workerReady              prometheus.Gauge
	serviceInfo              *prometheus.GaugeVec
}

func New(service, version string) *Metrics {
	registry := prometheus.NewRegistry()
	metrics := &Metrics{
		registry: registry,
		httpRequests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Namespace: namespace, Name: "http_requests_total", Help: "HTTP requests completed by method, route pattern and status class.",
		}, []string{"method", "route", "status_class"}),
		httpDuration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Namespace: namespace, Name: "http_request_duration_seconds", Help: "HTTP request latency by method and route pattern.",
			Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
		}, []string{"method", "route"}),
		httpActive:               prometheus.NewGauge(prometheus.GaugeOpts{Namespace: namespace, Name: "http_active_requests", Help: "Currently active HTTP requests, including upgraded WebSocket handlers."}),
		dependencyUp:             prometheus.NewGaugeVec(prometheus.GaugeOpts{Namespace: namespace, Name: "dependency_up", Help: "Last known dependency health (1 healthy, 0 unhealthy)."}, []string{"dependency"}),
		postgresQueries:          prometheus.NewCounterVec(prometheus.CounterOpts{Namespace: namespace, Name: "postgres_queries_total", Help: "PostgreSQL query operations by bounded operation class and result."}, []string{"operation", "result"}),
		postgresDuration:         prometheus.NewHistogramVec(prometheus.HistogramOpts{Namespace: namespace, Name: "postgres_query_duration_seconds", Help: "PostgreSQL query duration by bounded operation class.", Buckets: prometheus.DefBuckets}, []string{"operation"}),
		postgresPool:             prometheus.NewGaugeVec(prometheus.GaugeOpts{Namespace: namespace, Name: "postgres_pool_connections", Help: "PostgreSQL pool connections by state."}, []string{"state"}),
		redisOperations:          prometheus.NewCounterVec(prometheus.CounterOpts{Namespace: namespace, Name: "redis_operations_total", Help: "Redis realtime bus operations by operation and result."}, []string{"operation", "result"}),
		redisReconnects:          prometheus.NewCounter(prometheus.CounterOpts{Namespace: namespace, Name: "redis_reconnects_total", Help: "Realtime Redis subscription restart attempts."}),
		websocketConnections:     prometheus.NewGaugeVec(prometheus.GaugeOpts{Namespace: namespace, Name: "websocket_connections", Help: "Current WebSocket connections by bounded mode."}, []string{"mode"}),
		realtimeFailures:         prometheus.NewCounterVec(prometheus.CounterOpts{Namespace: namespace, Name: "realtime_publish_failures_total", Help: "Realtime cross-node publish/subscription failures by bounded reason."}, []string{"reason"}),
		realtimeQueueDropped:     prometheus.NewCounter(prometheus.CounterOpts{Namespace: namespace, Name: "realtime_queue_dropped_total", Help: "Realtime cross-node hints dropped because the local queue was full."}),
		outboxBacklog:            prometheus.NewGauge(prometheus.GaugeOpts{Namespace: namespace, Name: "outbox_backlog", Help: "Pending durable outbox events."}),
		outboxOldestSeconds:      prometheus.NewGauge(prometheus.GaugeOpts{Namespace: namespace, Name: "outbox_oldest_pending_seconds", Help: "Age in seconds of the oldest pending outbox event."}),
		pushJobs:                 prometheus.NewGaugeVec(prometheus.GaugeOpts{Namespace: namespace, Name: "push_jobs", Help: "Push jobs by operational state."}, []string{"state"}),
		pushOldestSeconds:        prometheus.NewGauge(prometheus.GaugeOpts{Namespace: namespace, Name: "push_oldest_pending_seconds", Help: "Age in seconds of the oldest pending Push job."}),
		pushRunning:              prometheus.NewGauge(prometheus.GaugeOpts{Namespace: namespace, Name: "push_running", Help: "Push jobs currently executing provider delivery."}),
		pushRetries:              prometheus.NewCounter(prometheus.CounterOpts{Namespace: namespace, Name: "push_retries_total", Help: "Push jobs deferred for retry."}),
		pushFailed:               prometheus.NewCounter(prometheus.CounterOpts{Namespace: namespace, Name: "push_failed_total", Help: "Push jobs dropped because delivery failed or retries were exhausted."}),
		pushProviderRequests:     prometheus.NewCounterVec(prometheus.CounterOpts{Namespace: namespace, Name: "push_provider_requests_total", Help: "Push provider attempts by provider and bounded result."}, []string{"provider", "result"}),
		pushProviderDuration:     prometheus.NewHistogramVec(prometheus.HistogramOpts{Namespace: namespace, Name: "push_provider_duration_seconds", Help: "Push provider request latency by provider.", Buckets: []float64{0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}}, []string{"provider"}),
		pushProviderAuthFailures: prometheus.NewCounterVec(prometheus.CounterOpts{Namespace: namespace, Name: "push_provider_auth_failures_total", Help: "Push provider credential/authentication failures."}, []string{"provider"}),
		pushProviderLastSuccess:  prometheus.NewGaugeVec(prometheus.GaugeOpts{Namespace: namespace, Name: "push_provider_last_success_timestamp_seconds", Help: "Unix timestamp of the latest accepted Push request for each provider."}, []string{"provider"}),
		pushProviderLastFailure:  prometheus.NewGaugeVec(prometheus.GaugeOpts{Namespace: namespace, Name: "push_provider_last_failure_timestamp_seconds", Help: "Unix timestamp of the latest failed Push request for each provider."}, []string{"provider"}),
		pushInvalidRatio:         prometheus.NewGaugeVec(prometheus.GaugeOpts{Namespace: namespace, Name: "push_invalid_endpoint_ratio", Help: "Invalid Push endpoints divided by all registered endpoints for each provider."}, []string{"provider"}),
		pushProviderConfigured:   prometheus.NewGaugeVec(prometheus.GaugeOpts{Namespace: namespace, Name: "push_provider_configured", Help: "Whether a Push provider is configured in this worker."}, []string{"provider"}),
		storageRequests:          prometheus.NewCounterVec(prometheus.CounterOpts{Namespace: namespace, Name: "object_storage_requests_total", Help: "Object storage operations by operation and result."}, []string{"operation", "result"}),
		storageDuration:          prometheus.NewHistogramVec(prometheus.HistogramOpts{Namespace: namespace, Name: "object_storage_duration_seconds", Help: "Object storage operation latency.", Buckets: prometheus.DefBuckets}, []string{"operation"}),
		smtpSends:                prometheus.NewCounterVec(prometheus.CounterOpts{Namespace: namespace, Name: "smtp_send_total", Help: "SMTP verification message sends by result."}, []string{"result"}),
		smtpDuration:             prometheus.NewHistogram(prometheus.HistogramOpts{Namespace: namespace, Name: "smtp_send_duration_seconds", Help: "SMTP verification message latency.", Buckets: prometheus.DefBuckets}),
		workerHeartbeat:          prometheus.NewGauge(prometheus.GaugeOpts{Namespace: namespace, Name: "worker_last_heartbeat_timestamp_seconds", Help: "Unix timestamp of the latest worker dispatch heartbeat."}),
		workerCycles:             prometheus.NewCounterVec(prometheus.CounterOpts{Namespace: namespace, Name: "worker_cycles_total", Help: "Worker dispatch cycles by result."}, []string{"result"}),
		workerReady:              prometheus.NewGauge(prometheus.GaugeOpts{Namespace: namespace, Name: "worker_ready", Help: "Worker readiness (1 ready, 0 not ready)."}),
		serviceInfo:              prometheus.NewGaugeVec(prometheus.GaugeOpts{Namespace: namespace, Name: "service_info", Help: "Static service build information."}, []string{"service", "version"}),
	}
	registry.MustRegister(
		metrics.httpRequests, metrics.httpDuration, metrics.httpActive, metrics.dependencyUp,
		metrics.postgresQueries, metrics.postgresDuration, metrics.postgresPool,
		metrics.redisOperations, metrics.redisReconnects, metrics.websocketConnections,
		metrics.realtimeFailures, metrics.realtimeQueueDropped, metrics.outboxBacklog, metrics.outboxOldestSeconds,
		metrics.pushJobs, metrics.pushOldestSeconds, metrics.pushRunning, metrics.pushRetries, metrics.pushFailed,
		metrics.pushProviderRequests, metrics.pushProviderDuration, metrics.pushProviderAuthFailures,
		metrics.pushProviderLastSuccess, metrics.pushProviderLastFailure, metrics.pushInvalidRatio, metrics.pushProviderConfigured,
		metrics.storageRequests, metrics.storageDuration,
		metrics.smtpSends, metrics.smtpDuration, metrics.workerHeartbeat, metrics.workerCycles, metrics.workerReady,
		metrics.serviceInfo,
		collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)
	service = boundedService(service)
	metrics.serviceInfo.WithLabelValues(service, boundedVersion(version)).Set(1)
	if service == "worker" {
		for _, provider := range []string{"FCM", "APNS", "UNIFIEDPUSH"} {
			metrics.pushProviderConfigured.WithLabelValues(provider).Set(0)
			metrics.pushProviderLastSuccess.WithLabelValues(provider).Set(0)
			metrics.pushProviderLastFailure.WithLabelValues(provider).Set(0)
		}
	}
	for _, provider := range []string{"FCM", "APNS", "UNIFIEDPUSH"} {
		metrics.pushInvalidRatio.WithLabelValues(provider).Set(0)
	}
	for _, state := range []string{"queued", "retry_waiting", "failed_recent"} {
		metrics.pushJobs.WithLabelValues(state).Set(0)
	}
	return metrics
}

func (m *Metrics) Handler() http.Handler {
	return promhttp.HandlerFor(m.registry, promhttp.HandlerOpts{EnableOpenMetrics: true})
}

func (m *Metrics) Registry() *prometheus.Registry { return m.registry }

func (m *Metrics) HTTPRequestStarted() { m.httpActive.Inc() }

func (m *Metrics) HTTPRequestFinished(method, route string, status int, duration time.Duration) {
	m.httpActive.Dec()
	method = boundedMethod(method)
	route = boundedRoute(route)
	m.httpRequests.WithLabelValues(method, route, statusClass(status)).Inc()
	m.httpDuration.WithLabelValues(method, route).Observe(duration.Seconds())
}

func (m *Metrics) SetDependencyHealth(name string, healthy bool) {
	value := 0.0
	if healthy {
		value = 1
	}
	m.dependencyUp.WithLabelValues(boundedDependency(name)).Set(value)
}

func (m *Metrics) ObservePostgresQuery(operation string, duration time.Duration, err error) {
	operation = boundedPostgresOperation(operation)
	result := "success"
	if errors.Is(err, pgx.ErrNoRows) {
		result = "not_found"
	} else if err != nil {
		result = "error"
	}
	m.postgresQueries.WithLabelValues(operation, result).Inc()
	m.postgresDuration.WithLabelValues(operation).Observe(duration.Seconds())
}

func (m *Metrics) UpdatePostgresPool(pool *pgxpool.Pool) {
	if pool == nil {
		return
	}
	stats := pool.Stat()
	m.postgresPool.WithLabelValues("acquired").Set(float64(stats.AcquiredConns()))
	m.postgresPool.WithLabelValues("idle").Set(float64(stats.IdleConns()))
	m.postgresPool.WithLabelValues("total").Set(float64(stats.TotalConns()))
	m.postgresPool.WithLabelValues("max").Set(float64(stats.MaxConns()))
}

func (m *Metrics) ObserveRedis(operation string, duration time.Duration, err error) {
	result := "success"
	if err != nil {
		result = "error"
	}
	m.redisOperations.WithLabelValues(boundedRedisOperation(operation), result).Inc()
	m.SetDependencyHealth("redis", err == nil)
}

func (m *Metrics) RedisReconnect() { m.redisReconnects.Inc() }

func (m *Metrics) WebSocketOpened(mode string) {
	m.websocketConnections.WithLabelValues(boundedWebSocketMode(mode)).Inc()
}
func (m *Metrics) WebSocketClosed(mode string) {
	m.websocketConnections.WithLabelValues(boundedWebSocketMode(mode)).Dec()
}
func (m *Metrics) RealtimePublishFailure(reason string) {
	m.realtimeFailures.WithLabelValues(boundedRealtimeReason(reason)).Inc()
}
func (m *Metrics) RealtimeQueueDropped() { m.realtimeQueueDropped.Inc() }

func (m *Metrics) PushJobStarted()  { m.pushRunning.Inc() }
func (m *Metrics) PushJobFinished() { m.pushRunning.Dec() }
func (m *Metrics) PushRetry()       { m.pushRetries.Inc() }
func (m *Metrics) PushFailed()      { m.pushFailed.Inc() }

func (m *Metrics) ObservePushProvider(provider, result string, duration time.Duration) {
	provider = boundedProvider(provider)
	result = boundedPushResult(result)
	m.pushProviderRequests.WithLabelValues(provider, result).Inc()
	m.pushProviderDuration.WithLabelValues(provider).Observe(duration.Seconds())
	now := float64(time.Now().Unix())
	if result == "success" {
		m.pushProviderLastSuccess.WithLabelValues(provider).Set(now)
	} else if result != "invalid_token" {
		m.pushProviderLastFailure.WithLabelValues(provider).Set(now)
	}
	if result == "auth_failure" {
		m.pushProviderAuthFailures.WithLabelValues(provider).Inc()
	}
}

func (m *Metrics) SetPushProviderConfigured(provider string, configured bool) {
	value := 0.0
	if configured {
		value = 1
	}
	m.pushProviderConfigured.WithLabelValues(boundedProvider(provider)).Set(value)
}

func (m *Metrics) ObserveObjectStorage(operation string, duration time.Duration, err error) {
	result := "success"
	if err != nil {
		result = "error"
	}
	m.storageRequests.WithLabelValues(boundedStorageOperation(operation), result).Inc()
	m.storageDuration.WithLabelValues(boundedStorageOperation(operation)).Observe(duration.Seconds())
}

func (m *Metrics) ObserveSMTP(duration time.Duration, err error) {
	result := "success"
	if err != nil {
		result = "error"
	}
	m.smtpSends.WithLabelValues(result).Inc()
	m.smtpDuration.Observe(duration.Seconds())
}

func (m *Metrics) WorkerHeartbeat(err error) {
	m.workerHeartbeat.Set(float64(time.Now().Unix()))
	result := "success"
	if err != nil {
		result = "error"
	}
	m.workerCycles.WithLabelValues(result).Inc()
}

func (m *Metrics) SetWorkerReady(ready bool) {
	value := 0.0
	if ready {
		value = 1
	}
	m.workerReady.Set(value)
}

// RunDependencySampler keeps last-known dependency health current even when no user request hits /ready.
func (m *Metrics) RunDependencySampler(ctx context.Context, checks map[string]ReadinessCheck, interval time.Duration) {
	if interval <= 0 {
		interval = 15 * time.Second
	}
	probe := func() {
		for name, check := range checks {
			checkCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
			err := check(checkCtx)
			cancel()
			m.SetDependencyHealth(name, err == nil)
		}
	}
	probe()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			probe()
		}
	}
}

func (m *Metrics) RunDatabaseSampler(ctx context.Context, pool *pgxpool.Pool, interval time.Duration) {
	if interval <= 0 {
		interval = 15 * time.Second
	}
	refresh := func() {
		refreshCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		_ = m.RefreshDatabaseState(refreshCtx, pool)
		cancel()
	}
	refresh()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			refresh()
		}
	}
}

// RefreshDatabaseState updates gauges that are best represented by the durable database state.
// It deliberately exports only aggregate counts and fixed provider names; no user/device/message
// identifiers or payload content enter metric labels.
func (m *Metrics) RefreshDatabaseState(ctx context.Context, pool *pgxpool.Pool) error {
	if pool == nil {
		return errors.New("postgres pool is nil")
	}
	m.UpdatePostgresPool(pool)

	var outboxCount int64
	var outboxOldest float64
	if err := pool.QueryRow(ctx, `
		SELECT count(*), COALESCE(EXTRACT(EPOCH FROM (now() - min(created_at))), 0)
		FROM outbox_events
		WHERE published_at IS NULL
	`).Scan(&outboxCount, &outboxOldest); err != nil {
		return err
	}
	m.outboxBacklog.Set(float64(outboxCount))
	m.outboxOldestSeconds.Set(max(0, outboxOldest))

	var queued, retryWaiting, failedRecent int64
	var pushOldest float64
	if err := pool.QueryRow(ctx, `
		SELECT
			count(*) FILTER (WHERE status='PENDING' AND attempts=0),
			count(*) FILTER (WHERE status='PENDING' AND attempts>0),
			count(*) FILTER (
				WHERE status='DROPPED'
				  AND created_at >= now() - interval '1 hour'
				  AND COALESCE(last_error,'') NOT IN ('RECIPIENT_INACTIVE','PUSH_DISABLED','SELF_EVENT','SUPPRESSED','NO_ACTIVE_ENDPOINT')
			),
			COALESCE(EXTRACT(EPOCH FROM (now() - min(created_at) FILTER (WHERE status='PENDING'))), 0)
		FROM push_jobs
	`).Scan(&queued, &retryWaiting, &failedRecent, &pushOldest); err != nil {
		return err
	}
	m.pushJobs.WithLabelValues("queued").Set(float64(queued))
	m.pushJobs.WithLabelValues("retry_waiting").Set(float64(retryWaiting))
	m.pushJobs.WithLabelValues("failed_recent").Set(float64(failedRecent))
	m.pushOldestSeconds.Set(max(0, pushOldest))

	for _, provider := range []string{"FCM", "APNS", "UNIFIEDPUSH"} {
		m.pushInvalidRatio.WithLabelValues(provider).Set(0)
	}
	rows, err := pool.Query(ctx, `
		SELECT provider,
		       count(*) FILTER (WHERE status='INVALID')::double precision / NULLIF(count(*), 0)::double precision
		FROM device_push_endpoints
		GROUP BY provider
	`)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var provider string
		var ratio float64
		if err := rows.Scan(&provider, &ratio); err != nil {
			return err
		}
		m.pushInvalidRatio.WithLabelValues(boundedProvider(provider)).Set(ratio)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	return nil
}

func boundedMethod(raw string) string {
	switch strings.ToUpper(strings.TrimSpace(raw)) {
	case http.MethodGet, http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete, http.MethodOptions, http.MethodHead:
		return strings.ToUpper(strings.TrimSpace(raw))
	default:
		return "OTHER"
	}
}

func boundedRoute(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "unmatched"
	}
	if len(raw) > 160 {
		return "other"
	}
	// Go ServeMux patterns come from static registration strings. Reject anything that
	// looks like a raw query/full URL so accidental high-cardinality labels fail closed.
	if strings.ContainsAny(raw, "?#") || strings.Contains(raw, "://") {
		return "other"
	}
	return raw
}

func statusClass(status int) string {
	if status < 100 || status > 599 {
		return "other"
	}
	return strconv.Itoa(status/100) + "xx"
}

func boundedDependency(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "postgres", "redis", "storage", "smtp", "livekit", "turn":
		return strings.ToLower(strings.TrimSpace(raw))
	default:
		return "other"
	}
}

func boundedPostgresOperation(raw string) string {
	switch strings.ToUpper(strings.TrimSpace(raw)) {
	case "SELECT", "INSERT", "UPDATE", "DELETE", "BEGIN", "COMMIT", "ROLLBACK", "COPY", "BATCH":
		return strings.ToUpper(strings.TrimSpace(raw))
	default:
		return "OTHER"
	}
}

func boundedRedisOperation(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "connect", "ping", "publish", "subscribe":
		return strings.ToLower(strings.TrimSpace(raw))
	default:
		return "other"
	}
}

func boundedWebSocketMode(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "authenticated", "legacy":
		return strings.ToLower(strings.TrimSpace(raw))
	default:
		return "other"
	}
}

func boundedRealtimeReason(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "publish", "subscribe":
		return strings.ToLower(strings.TrimSpace(raw))
	default:
		return "other"
	}
}

func boundedProvider(raw string) string {
	switch strings.ToUpper(strings.TrimSpace(raw)) {
	case "FCM", "APNS", "UNIFIEDPUSH":
		return strings.ToUpper(strings.TrimSpace(raw))
	default:
		return "OTHER"
	}
}

func boundedPushResult(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "success", "invalid_token", "retryable", "auth_failure", "failure", "unconfigured":
		return strings.ToLower(strings.TrimSpace(raw))
	default:
		return "failure"
	}
}

func boundedStorageOperation(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "stat", "delete":
		return strings.ToLower(strings.TrimSpace(raw))
	default:
		return "other"
	}
}

func boundedService(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "api", "worker":
		return strings.ToLower(strings.TrimSpace(raw))
	default:
		return "other"
	}
}

func boundedVersion(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "dev"
	}
	if len(raw) > 64 {
		return raw[:64]
	}
	return raw
}
