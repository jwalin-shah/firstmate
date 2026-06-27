package main

import (
	"strings"
	"testing"
)

func TestRewrite_ShortPrompt(t *testing.T) {
	// rewrite() doesn't check prompt length; it calls the MLX server.
	// Without a running server, it returns an error.
	got, err := rewrite("http://127.0.0.1:1", "test-model", "short")
	if err == nil {
		t.Error("expected error for unreachable server")
	}
	if got != "" {
		t.Errorf("expected empty string on error, got %q", got)
	}
}

func TestRewrite_EmptyModel(t *testing.T) {
	got, err := rewrite("http://127.0.0.1:1", "", "this is a longer prompt for testing")
	if err == nil {
		t.Error("expected error for unreachable server")
	}
	if got != "" {
		t.Errorf("expected empty string on error, got %q", got)
	}
}

func TestSkipPrefixes(t *testing.T) {
	prefixes := []string{
		"```code block",
		"# comment",
		"/command",
		"fix this bug",
		"add a feature",
		"delete that file",
		"run the tests",
		"can you help me",
		"please do this",
		"make sure it works",
		"could you check",
	}
	for _, p := range prefixes {
		lower := strings.ToLower(p)
		matched := false
		for _, sp := range skipPrefixes {
			if strings.HasPrefix(lower, sp) {
				matched = true
				break
			}
		}
		if !matched {
			t.Errorf("expected %q to match a skip prefix", p)
		}
	}
}

func TestDefaultModel(t *testing.T) {
	if defaultModel == "" {
		t.Error("defaultModel must not be empty")
	}
}

func TestMinPromptLen(t *testing.T) {
	if minPromptLen <= 0 {
		t.Error("minPromptLen must be positive")
	}
}
