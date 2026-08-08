package realtimev1

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestSharedFixturesRoundTrip(t *testing.T) {
	tests := []struct {
		file     string
		wantType Type
	}{
		{file: "hello.json", wantType: TypeHello},
		{file: "event_available.json", wantType: TypeEventAvailable},
		{file: "ping.json", wantType: TypePing},
	}

	for _, test := range tests {
		t.Run(test.file, func(t *testing.T) {
			path := filepath.Join("..", "..", "..", "packages", "realtime_protocol", "fixtures", test.file)
			contents, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read fixture: %v", err)
			}

			var envelope Envelope
			if err := json.Unmarshal(contents, &envelope); err != nil {
				t.Fatalf("decode fixture: %v", err)
			}
			if envelope.Type != test.wantType {
				t.Fatalf("type = %q, want %q", envelope.Type, test.wantType)
			}
			if err := envelope.Validate(); err != nil {
				t.Fatalf("Validate() error = %v", err)
			}
			encoded, err := json.Marshal(envelope)
			if err != nil {
				t.Fatalf("encode fixture: %v", err)
			}
			var roundTrip Envelope
			if err := json.Unmarshal(encoded, &roundTrip); err != nil {
				t.Fatalf("decode round trip: %v", err)
			}
			if roundTrip.Type != envelope.Type {
				t.Fatalf("round-trip type = %q, want %q", roundTrip.Type, envelope.Type)
			}
		})
	}
}

func TestValidateRejectsProtocolMismatchAndMissingFields(t *testing.T) {
	tests := []Envelope{
		{Type: TypeHello, ProtocolVersion: 2, DeviceID: "dev_fixture01"},
		{Type: TypeHello, ProtocolVersion: 1, DeviceID: ""},
		{Type: TypeEventAvailable, EventID: "evt_x", Cursor: ""},
		{Type: TypePing, Timestamp: -1},
		{Type: "UNKNOWN"},
	}

	for _, envelope := range tests {
		if err := envelope.Validate(); err == nil {
			t.Fatalf("Validate(%#v) unexpectedly succeeded", envelope)
		}
	}
}
