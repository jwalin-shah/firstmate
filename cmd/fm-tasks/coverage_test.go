package main

import (
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSectionRank(t *testing.T) {
	tests := []struct {
		status string
		want   int
	}{
		{"inflight", 0},
		{"queued", 1},
		{"done", 2},
		{"unknown", 3},
		{"", 3},
	}
	for _, tc := range tests {
		got := sectionRank(tc.status)
		if got != tc.want {
			t.Errorf("sectionRank(%q) = %d, want %d", tc.status, got, tc.want)
		}
	}
}

func TestFieldValue_AllFields(t *testing.T) {
	t1 := &Task{
		ID: "abc", Title: "my task", Repo: "repo-path", Kind: "scout", Status: "queued",
		BlockedBy:     sql.NullString{String: "dep-1", Valid: true},
		BlockedReason: sql.NullString{String: "waiting", Valid: true},
		PRURL:         sql.NullString{String: "https://github.com/owner/repo/pull/1", Valid: true},
		ReportPath:    sql.NullString{String: "data/report.md", Valid: true},
		AddedAt:       "2026-01-01",
		StartedAt:     sql.NullString{String: "2026-01-02", Valid: true},
		DoneAt:        sql.NullString{String: "2026-01-03", Valid: true},
		Meta:          sql.NullString{String: `{"key":"val"}`, Valid: true},
	}

	cases := []struct {
		field string
		want  string
		ok    bool
	}{
		{"id", "abc", true},
		{"title", "my task", true},
		{"repo", "repo-path", true},
		{"kind", "scout", true},
		{"status", "queued", true},
		{"blocked_by", "dep-1", true},
		{"blocked_reason", "waiting", true},
		{"pr_url", "https://github.com/owner/repo/pull/1", true},
		{"report_path", "data/report.md", true},
		{"added_at", "2026-01-01", true},
		{"started_at", "2026-01-02", true},
		{"done_at", "2026-01-03", true},
		{"meta", `{"key":"val"}`, true},
		{"bogus", "", false},
	}
	for _, tc := range cases {
		got, ok := fieldValue(t1, tc.field)
		if ok != tc.ok || got != tc.want {
			t.Errorf("fieldValue(%q) = (%q, %v), want (%q, %v)", tc.field, got, ok, tc.want, tc.ok)
		}
	}
}

func TestParseFields_ValidSpec(t *testing.T) {
	got, err := parseFields("id,title,status")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"id", "title", "status"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestParseFields_EmptyTokens(t *testing.T) {
	got, err := parseFields("id,,repo")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"id", "repo"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestParseFields_WhitespaceTokens(t *testing.T) {
	got, err := parseFields(" id , repo ")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"id", "repo"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestParseFields_AllFields(t *testing.T) {
	got, err := parseFields(strings.Join(allFields, ","))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(allFields) {
		t.Errorf("got %d fields, want %d", len(got), len(allFields))
	}
	for i, f := range allFields {
		if got[i] != f {
			t.Errorf("field %d: got %q, want %q", i, got[i], f)
		}
	}
}

func TestParseBacklog_EmptyFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "empty.md")
	if err := os.WriteFile(path, []byte(""), 0o644); err != nil {
		t.Fatal(err)
	}
	f, _ := os.Open(path)
	defer f.Close()
	entries, err := parseBacklog(f)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("want 0 entries, got %d", len(entries))
	}
}

func TestParseBacklog_NoSections(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "nosection.md")
	body := `Just some text
- task-1 This should not parse
More text
`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	f, _ := os.Open(path)
	defer f.Close()
	entries, err := parseBacklog(f)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("want 0 entries, got %d", len(entries))
	}
}

func TestParseBacklog_SectionVariants(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "variants.md")
	body := `## In-Flight
- t1 Title one
## Queue
- t2 Title two
## Done
- t3 Title three
`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	f, _ := os.Open(path)
	defer f.Close()
	entries, err := parseBacklog(f)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 3 {
		t.Fatalf("want 3 entries, got %d", len(entries))
	}
}

func TestParseBacklogLine_ScoutNoBlock(t *testing.T) {
	e := parseBacklogLine("abc scout Scout mission", "queued", "now")
	if e == nil {
		t.Fatal("expected entry")
	}
	if e.Kind != "scout" || e.Title != "Scout mission" || e.BlockedBy != "" {
		t.Errorf("wrong: %+v", e)
	}
}

func TestParseBacklogLine_KindAsTitle(t *testing.T) {
	e := parseBacklogLine("abc ship", "queued", "now")
	if e != nil {
		t.Error("expected nil: 'ship' consumed as kind token, title becomes empty")
	}
}

func TestParseBacklogLine_BlockWithInvalidID(t *testing.T) {
	e := parseBacklogLine("abc ship Title block:bad!id", "queued", "now")
	if e == nil {
		t.Fatal("expected entry")
	}
	if e.Title != "Title" || e.BlockedBy != "" {
		t.Errorf("block should not be set for invalid ID: %+v", e)
	}
}

func TestParseBacklogLine_InflightSetsStartedAt(t *testing.T) {
	e := parseBacklogLine("abc ship Title", "inflight", "2026-01-01 12:00:00")
	if e == nil {
		t.Fatal("expected entry")
	}
	if e.StartedAt != "2026-01-01 12:00:00" {
		t.Errorf("inflight should set StartedAt: %+v", e)
	}
	if e.DoneAt != "" {
		t.Errorf("inflight should not set DoneAt: %+v", e)
	}
}

func TestParseBacklogLine_DoneSetsTimestamps(t *testing.T) {
	e := parseBacklogLine("abc ship Title", "done", "2026-01-01 12:00:00")
	if e == nil {
		t.Fatal("expected entry")
	}
	if e.StartedAt != "2026-01-01 12:00:00" {
		t.Errorf("done should set StartedAt: %+v", e)
	}
	if e.DoneAt != "2026-01-01 12:00:00" {
		t.Errorf("done should set DoneAt: %+v", e)
	}
}

func TestIsValidID_DotAllowed(t *testing.T) {
	if !isValidID("abc.123") {
		t.Error("expected dot to be allowed")
	}
}

func TestIsValidID_MixedCase(t *testing.T) {
	if !isValidID("ABC-123_def") {
		t.Error("expected mixed case to be allowed")
	}
}
