package contacts

import (
	"testing"

	"github.com/google/uuid"
)

func TestDirectPairKeyIsOrderIndependent(t *testing.T) {
	a := uuid.MustParse("00000000-0000-0000-0000-000000000010")
	b := uuid.MustParse("00000000-0000-0000-0000-000000000002")
	if got, want := directPairKey(a, b), directPairKey(b, a); got != want {
		t.Fatalf("directPairKey order mismatch: %q != %q", got, want)
	}
}

func TestNormalizeTagsDeduplicatesCaseAndUnicodeWidth(t *testing.T) {
	tags, err := normalizeTags([]string{" Work ", "work", "ＷＯＲＫ", "朋友"})
	if err != nil {
		t.Fatal(err)
	}
	if len(tags) != 2 {
		t.Fatalf("len(tags)=%d, want 2: %#v", len(tags), tags)
	}
	if tags[0].Name != "Work" || tags[0].Normalized != "work" {
		t.Fatalf("first tag=%#v", tags[0])
	}
	if tags[1].Name != "朋友" {
		t.Fatalf("second tag=%#v", tags[1])
	}
}

func TestNormalizeTagsRejectsTooMany(t *testing.T) {
	raw := make([]string, maximumTagsPerContact+1)
	for index := range raw {
		raw[index] = "tag"
	}
	if _, err := normalizeTags(raw); err == nil {
		t.Fatal("expected too-many-tags error")
	}
}

func TestNormalizeBoundedTextCountsRunes(t *testing.T) {
	if _, err := normalizeBoundedText("你好世界", 3, true, "message"); err == nil {
		t.Fatal("expected rune length error")
	}
	value, err := normalizeBoundedText("  你好  ", 2, true, "message")
	if err != nil {
		t.Fatal(err)
	}
	if value != "你好" {
		t.Fatalf("normalized value=%q", value)
	}
}

func TestNormalizePageBounds(t *testing.T) {
	page, size := normalizePage(0, 1000)
	if page != 1 || size != maximumPageSize {
		t.Fatalf("page=%d size=%d", page, size)
	}
	page, size = normalizePage(3, 0)
	if page != 3 || size != defaultPageSize {
		t.Fatalf("page=%d size=%d", page, size)
	}
}
