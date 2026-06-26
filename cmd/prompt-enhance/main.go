// prompt-enhance: UserPromptSubmit hook that rewrites casual prompts into
// structured engineering requests via the local MLX server (Qwopus).
//
// Reads Claude Code's JSON stdin: {"prompt": "...", "session_id": "..."}
// Outputs <structured_intent>...</structured_intent> prepended as context.
// Falls through silently on any error or if MLX is not running.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

const (
	defaultMLXURL   = "http://127.0.0.1:8082/v1"
	defaultModel    = "shuhulx/Qwopus3.5-4B-Coder-Fable5-v1-MLX-4bit"
	minPromptLen    = 120
	probeTimeoutMS  = 1000
	rewriteTimeout  = 8 * time.Second
	maxOutputTokens = 300
)

var skipPrefixes = []string{
	"```", "#", "/", "fix ", "add ", "delete ", "run ",
	"can you", "please", "make sure", "could you",
}

const system = "You are a prompt structurer for an AI coding assistant on a Mac. " +
	"The user speaks casually and fast — often voice-dictated or typed quickly. " +
	"Rewrite their message as a clear, structured engineering request. " +
	"Keep technical terms exact. Keep it under 150 words. " +
	"Output ONLY the rewritten request — no intro, no explanation, no quotes."

func main() {
	raw, err := io.ReadAll(os.Stdin)
	if err != nil || len(raw) == 0 {
		return
	}

	var inp struct {
		Prompt string `json:"prompt"`
	}
	if err := json.Unmarshal(raw, &inp); err != nil {
		inp.Prompt = strings.TrimSpace(string(raw))
	}

	prompt := strings.TrimSpace(inp.Prompt)
	if len(prompt) < minPromptLen {
		return
	}
	lower := strings.ToLower(prompt)
	for _, p := range skipPrefixes {
		if strings.HasPrefix(lower, p) {
			return
		}
	}

	mlxURL := os.Getenv("MLX_SERVER_URL")
	if mlxURL == "" {
		mlxURL = defaultMLXURL
	}
	model := os.Getenv("MLX_MODEL")
	if model == "" {
		model = defaultModel
	}

	// Fast probe — skip if MLX not running.
	probe, _ := http.NewRequest("GET", mlxURL+"/models", nil)
	probeClient := &http.Client{Timeout: time.Duration(probeTimeoutMS) * time.Millisecond}
	if resp, err := probeClient.Do(probe); err != nil {
		return
	} else {
		resp.Body.Close()
	}

	rewritten, err := rewrite(mlxURL, model, prompt)
	if err != nil || rewritten == "" || rewritten == prompt {
		return
	}
	fmt.Printf("<structured_intent>\n%s\n</structured_intent>\n", rewritten)
}

func rewrite(mlxURL, model, prompt string) (string, error) {
	body, _ := json.Marshal(map[string]any{
		"model": model,
		"messages": []map[string]string{
			{"role": "system", "content": system},
			{"role": "user", "content": prompt},
		},
		"max_tokens":  maxOutputTokens,
		"temperature": 0.3,
	})

	req, _ := http.NewRequest("POST", mlxURL+"/chat/completions", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: rewriteTimeout}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	var out struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", err
	}
	if len(out.Choices) == 0 {
		return "", nil
	}
	return strings.TrimSpace(out.Choices[0].Message.Content), nil
}
