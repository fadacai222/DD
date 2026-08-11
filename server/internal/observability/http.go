package observability

import (
	"context"
	"encoding/json"
	"net/http"
	"time"
)

type ReadinessCheck func(context.Context) error

func NewOperationalHandler(metrics http.Handler, checks map[string]ReadinessCheck) http.Handler {
	mux := http.NewServeMux()
	mux.Handle("/metrics", metrics)
	mux.HandleFunc("/live", func(response http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodGet {
			response.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		writeOperationalJSON(response, http.StatusOK, map[string]any{"status": "ok"})
	})
	mux.HandleFunc("/ready", func(response http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodGet {
			response.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		states := make(map[string]string, len(checks))
		ready := true
		for name, check := range checks {
			ctx, cancel := context.WithTimeout(request.Context(), 2*time.Second)
			err := check(ctx)
			cancel()
			if err != nil {
				states[name] = "failed"
				ready = false
				continue
			}
			states[name] = "ok"
		}
		status := http.StatusOK
		state := "ready"
		if !ready {
			status = http.StatusServiceUnavailable
			state = "not_ready"
		}
		writeOperationalJSON(response, status, map[string]any{"status": state, "checks": states})
	})
	return mux
}

func writeOperationalJSON(response http.ResponseWriter, status int, value any) {
	response.Header().Set("Content-Type", "application/json; charset=utf-8")
	response.Header().Set("Cache-Control", "no-store")
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(value)
}
