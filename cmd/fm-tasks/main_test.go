// fm-tasks: unit tests. Most behavior is exercised via the CLI end-to-end in
// scripts; here we cover the parts that are cheapest to break and most painful
// to debug interactively: backlog parsing and meta merge ordering.
package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseBacklog_BasicSections(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "backlog.md")
	body := `# Backlog

## In flight

- inflight-1 ship Title one
- inflight-2 scout Quick scout block:inflight-1

## Queued

- queued-1 ship Build queued one

## Done

- done-1 ship Completed task
`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	entries, err := parseBacklog(f)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 4 {
		t.Fatalf("want 4 entries, got %d", len(entries))
	}
	byID := map[string]backlogEntry{}
	for _, e := range entries {
		byID[e.ID] = e
	}
	if e := byID["inflight-1"]; e.Status != "inflight" || e.Kind != "ship" || e.Title != "Title one" {
		t.Errorf("inflight-1 wrong: %+v", e)
	}
	if e := byID["inflight-2"]; e.Status != "inflight" || e.Kind != "scout" || e.BlockedBy != "inflight-1" {
		t.Errorf("inflight-2 wrong: %+v", e)
	}
	if e := byID["queued-1"]; e.Status != "queued" || e.StartedAt != "" {
		t.Errorf("queued-1 wrong: %+v", e)
	}
	if e := byID["done-1"]; e.Status != "done" || e.StartedAt == "" || e.DoneAt == "" {
		t.Errorf("done-1 wrong: %+v", e)
	}
}

func TestParseBacklog_OrderIsStable(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "backlog.md")
	body := `## Queued

- z-queued Title z-queued
- a-queued Title a-queued

## In flight

- z-inflight Title z-inflight
- a-inflight Title a-inflight
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
	if len(entries) != 4 {
		t.Fatalf("want 4 entries, got %d", len(entries))
	}
	// Section order: inflight, queued, done (rank 0, 1, 2).
	want := []string{"a-inflight", "z-inflight", "a-queued", "z-queued"}
	for i, w := range want {
		if entries[i].ID != w {
			t.Errorf("entry %d: want %q, got %q", i, w, entries[i].ID)
		}
	}
}

func TestParseBacklog_UnknownSectionsIgnored(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "backlog.md")
	body := `## Misc notes

- ship-1 This should not parse

## Queued

- ship-2 This should parse
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
	if len(entries) != 1 || entries[0].ID != "ship-2" {
		t.Fatalf("want only ship-2, got %+v", entries)
	}
}

func TestParseBacklogLine_StripsAnnotations(t *testing.T) {
	e := parseBacklogLine("abc ship Build the thing block:dep-1", "queued", "2026-01-01 00:00:00")
	if e == nil {
		t.Fatal("expected entry")
	}
	if e.Kind != "ship" || e.Title != "Build the thing" || e.BlockedBy != "dep-1" {
		t.Errorf("wrong: %+v", e)
	}
}

func TestParseBacklogLine_RejectsBadID(t *testing.T) {
	// "has space" is fine: id="has" is a valid slug; the rest is the title.
	if parseBacklogLine("has space Title here", "queued", "now") == nil {
		t.Error("expected non-nil: id \"has\" is valid, \"space Title here\" is the title")
	}
	// "x!y" is rejected because '!' is not in the slug alphabet.
	if parseBacklogLine("x!y Title here", "queued", "now") != nil {
		t.Error("expected nil for bad id containing '!'")
	}
	// Empty input is rejected.
	if parseBacklogLine("", "queued", "now") != nil {
		t.Error("expected nil for empty line")
	}
	// Lines with no whitespace separator are not parseable.
	if parseBacklogLine("idonly", "queued", "now") != nil {
		t.Error("expected nil when no title is present")
	}
	// A well-formed line is accepted.
	if parseBacklogLine("ok-id title here", "queued", "now") == nil {
		t.Error("expected non-nil for good id with title")
	}
}

func TestFieldValue_Nulls(t *testing.T) {
	t1 := &Task{ID: "x", Title: "y", Repo: "r", Kind: "ship", Status: "queued", AddedAt: "now"}
	if _, ok := fieldValue(t1, "blocked_by"); ok {
		t.Error("expected null blocked_by to be absent")
	}
	if _, ok := fieldValue(t1, "pr_url"); ok {
		t.Error("expected null pr_url to be absent")
	}
	if v, ok := fieldValue(t1, "id"); !ok || v != "x" {
		t.Errorf("id wrong: %v %q", ok, v)
	}
}

func TestParseFields_Defaults(t *testing.T) {
	got, err := parseFields("")
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Join(fieldsDefault, ",")
	if strings.Join(got, ",") != want {
		t.Errorf("default fields: want %q, got %q", want, strings.Join(got, ","))
	}
}

func TestParseFields_RejectsUnknown(t *testing.T) {
	if _, err := parseFields("id,bogus"); err == nil {
		t.Error("expected error for unknown field")
	}
}

func TestIsValidID(t *testing.T) {
	cases := map[string]bool{
		"a":          true,
		"abc-123":    true,
		"a_b":        true,
		"path/to/id": true,
		"":           false,
		"has space":  false,
		"x!y":        false,
		"/leading":   false,
	}
	for in, want := range cases {
		if got := isValidID(in); got != want {
			t.Errorf("isValidID(%q) = %v, want %v", in, got, want)
		}
	}
}
