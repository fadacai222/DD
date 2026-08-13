package httpapi

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"example.com/selfhosted-im/server/internal/calls"
)

func TestWriteFormalCallsErrorDistinguishesMissingContact(t *testing.T) {
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/api/v1/calls", nil)

	(&server{}).writeFormalCallsError(recorder, request, calls.ErrContactRequired)

	if recorder.Code != http.StatusForbidden {
		t.Fatalf("status=%d want %d", recorder.Code, http.StatusForbidden)
	}
	if body := recorder.Body.String(); !strings.Contains(body, `"code":"CALL_CONTACT_REQUIRED"`) {
		t.Fatalf("body=%s does not contain CALL_CONTACT_REQUIRED", body)
	}
}
