package messaging

import (
	"errors"
	"strings"
	"testing"
)

func TestScanMentionCandidates(t *testing.T) {
	tests := []struct {
		name       string
		text       string
		wantHandle []string
		wantOffset []int
		wantLength []int
	}{
		{name: "plain", text: "@alice", wantHandle: []string{"alice"}, wantOffset: []int{0}, wantLength: []int{6}},
		{name: "chinese prefix", text: "你好@alice", wantHandle: []string{"alice"}, wantOffset: []int{2}, wantLength: []int{6}},
		{name: "parentheses", text: "(@alice)", wantHandle: []string{"alice"}, wantOffset: []int{1}, wantLength: []int{6}},
		{name: "chinese punctuation", text: "@alice，晚上好", wantHandle: []string{"alice"}, wantOffset: []int{0}, wantLength: []int{6}},
		{name: "two mentions", text: "@alice/@bob", wantHandle: []string{"alice", "bob"}, wantOffset: []int{0, 7}, wantLength: []int{6, 4}},
		{name: "normalize uppercase", text: "@Alice", wantHandle: []string{"alice"}, wantOffset: []int{0}, wantLength: []int{6}},
		{name: "email", text: "hello@example.com"},
		{name: "double at", text: "@@alice"},
		{name: "too short", text: "@a"},
		{name: "underscore", text: "@alice_01", wantHandle: []string{"alice_01"}, wantOffset: []int{0}, wantLength: []int{9}},
		{name: "emoji utf16", text: "Emoji😀在前 @alice", wantHandle: []string{"alice"}, wantOffset: []int{10}, wantLength: []int{6}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := scanMentionCandidates(tt.text)
			if err != nil {
				t.Fatalf("scanMentionCandidates() error = %v", err)
			}
			if len(got) != len(tt.wantHandle) {
				t.Fatalf("candidate count = %d, want %d: %#v", len(got), len(tt.wantHandle), got)
			}
			for i := range got {
				if got[i].Handle != tt.wantHandle[i] || got[i].Offset != tt.wantOffset[i] || got[i].Length != tt.wantLength[i] {
					t.Fatalf("candidate[%d] = %#v", i, got[i])
				}
			}
		})
	}
}

func TestMentionAllRolePermission(t *testing.T) {
	for _, test := range []struct {
		role string
		want bool
	}{
		{role: "OWNER", want: true},
		{role: "ADMIN", want: true},
		{role: "MEMBER", want: false},
		{role: "", want: false},
	} {
		if got := canMentionAllRole(test.role); got != test.want {
			t.Fatalf("canMentionAllRole(%q)=%v want %v", test.role, got, test.want)
		}
	}
}

func TestScanMentionCandidatesLimits(t *testing.T) {
	tooManyOccurrences := strings.Repeat("@alice ", MaximumMentionEntities+1)
	if _, err := scanMentionCandidates(tooManyOccurrences); !errors.Is(err, ErrTooManyMentions) {
		t.Fatalf("occurrence limit error = %v", err)
	}

	parts := make([]string, 0, MaximumMentionUsers+1)
	for i := 0; i < MaximumMentionUsers+1; i++ {
		parts = append(parts, "@user"+twoDigits(i))
	}
	if _, err := scanMentionCandidates(strings.Join(parts, " ")); !errors.Is(err, ErrTooManyMentions) {
		t.Fatalf("unique user limit error = %v", err)
	}
}

func twoDigits(value int) string {
	return string([]byte{'0' + byte(value/10), '0' + byte(value%10)})
}
