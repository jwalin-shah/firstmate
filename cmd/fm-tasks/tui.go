package main

import (
	"database/sql"
	"fmt"
	"os"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// Styles — tuxedo-inspired: minimal, high-contrast.
var (
	styleHeader   = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("12"))
	styleSelected = lipgloss.NewStyle().Background(lipgloss.Color("238")).Bold(true)
	styleDone     = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	styleFailed   = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	styleInflight = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	styleQueued   = lipgloss.NewStyle().Foreground(lipgloss.Color("7"))
	styleScout    = lipgloss.NewStyle().Foreground(lipgloss.Color("13"))
	styleMuted    = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	styleMsg      = lipgloss.NewStyle().Foreground(lipgloss.Color("6"))
	styleHelp     = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
)

type tuiModel struct {
	db      *sql.DB
	tasks   []Task
	cursor  int
	filter  string // repo filter (empty = all)
	input   string // current / search input
	mode    string // "" | "filter" | "help"
	message string
}

type reloadMsg []Task

func loadTasks(db *sql.DB, repoFilter string) ([]Task, error) {
	// Fetch all non-done tasks + last 10 done, ordered for display.
	query := `
		SELECT id, title, repo, kind, status,
		       COALESCE(blocked_by,''), COALESCE(pr_url,''),
		       COALESCE(added_at,''), COALESCE(started_at,''), COALESCE(done_at,'')
		FROM tasks
		WHERE (status != 'done' AND status != 'failed')
		   OR done_at >= datetime('now', '-7 days')
	`
	args := []any{}
	if repoFilter != "" {
		query += " AND repo LIKE ?"
		args = append(args, "%"+repoFilter+"%")
	}
	query += " ORDER BY CASE status WHEN 'inflight' THEN 0 WHEN 'queued' THEN 1 ELSE 2 END, added_at"

	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var tasks []Task
	for rows.Next() {
		var t Task
		var blockedBy, prURL, addedAt, startedAt, doneAt string
		if err := rows.Scan(&t.ID, &t.Title, &t.Repo, &t.Kind, &t.Status,
			&blockedBy, &prURL, &addedAt, &startedAt, &doneAt); err != nil {
			continue
		}
		if blockedBy != "" {
			t.BlockedBy = sql.NullString{String: blockedBy, Valid: true}
		}
		if prURL != "" {
			t.PRURL = sql.NullString{String: prURL, Valid: true}
		}
		t.AddedAt = addedAt
		tasks = append(tasks, t)
	}
	return tasks, rows.Err()
}

func doReload(db *sql.DB, filter string) tea.Cmd {
	return func() tea.Msg {
		tasks, _ := loadTasks(db, filter)
		return reloadMsg(tasks)
	}
}

func initTUI(db *sql.DB) tuiModel {
	tasks, _ := loadTasks(db, "")
	return tuiModel{db: db, tasks: tasks}
}

func (m tuiModel) Init() tea.Cmd { return nil }

func (m tuiModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case reloadMsg:
		m.tasks = []Task(msg)
		if m.cursor >= len(m.tasks) && len(m.tasks) > 0 {
			m.cursor = len(m.tasks) - 1
		}
		return m, nil

	case tea.KeyMsg:
		if m.mode == "filter" {
			return m.handleFilterKey(msg)
		}
		if m.mode == "help" {
			m.mode = ""
			return m, nil
		}
		return m.handleNormalKey(msg)
	}
	return m, nil
}

func (m tuiModel) handleNormalKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	m.message = ""
	switch msg.String() {
	case "q", "ctrl+c":
		return m, tea.Quit
	case "j", "down":
		if m.cursor < len(m.tasks)-1 {
			m.cursor++
		}
	case "k", "up":
		if m.cursor > 0 {
			m.cursor--
		}
	case "g":
		m.cursor = 0
	case "G":
		if len(m.tasks) > 0 {
			m.cursor = len(m.tasks) - 1
		}
	case "ctrl+d":
		m.cursor = min(m.cursor+10, len(m.tasks)-1)
	case "ctrl+u":
		m.cursor = max(m.cursor-10, 0)
	case "x":
		if t := m.selectedTask(); t != nil && (t.Status == "inflight" || t.Status == "queued") {
			if err := transitionTask(m.db, t.ID, "done"); err != nil {
				m.message = "error: " + err.Error()
			} else {
				m.message = "marked done: " + t.ID
				return m, doReload(m.db, m.filter)
			}
		}
	case "f":
		if t := m.selectedTask(); t != nil && (t.Status == "inflight" || t.Status == "queued") {
			if err := transitionTask(m.db, t.ID, "failed"); err != nil {
				m.message = "error: " + err.Error()
			} else {
				m.message = "marked failed: " + t.ID
				return m, doReload(m.db, m.filter)
			}
		}
	case "r":
		return m, doReload(m.db, m.filter)
	case "/":
		m.mode = "filter"
		m.input = ""
	case "?":
		m.mode = "help"
	}
	return m, nil
}

func (m tuiModel) handleFilterKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "enter":
		m.filter = m.input
		m.mode = ""
		m.cursor = 0
		return m, doReload(m.db, m.filter)
	case "esc":
		m.mode = ""
		m.input = ""
	case "backspace", "ctrl+h":
		if len(m.input) > 0 {
			m.input = m.input[:len(m.input)-1]
		}
	default:
		if len(msg.String()) == 1 {
			m.input += msg.String()
		}
	}
	return m, nil
}

func (m tuiModel) selectedTask() *Task {
	if len(m.tasks) == 0 || m.cursor >= len(m.tasks) {
		return nil
	}
	return &m.tasks[m.cursor]
}

func transitionTask(db *sql.DB, id, status string) error {
	var col string
	switch status {
	case "done":
		col = "done_at"
	case "failed":
		col = "done_at"
	default:
		return fmt.Errorf("unknown status %q", status)
	}
	_, err := db.Exec(
		fmt.Sprintf("UPDATE tasks SET status=?, %s=datetime('now') WHERE id=? AND status IN ('inflight','queued')", col),
		status, id,
	)
	return err
}

func (m tuiModel) View() string {
	if m.mode == "help" {
		return helpView()
	}

	var b strings.Builder
	title := "fm-tasks"
	if m.filter != "" {
		title += " [/" + m.filter + "]"
	}
	b.WriteString(styleHeader.Render(title) + "\n\n")

	if len(m.tasks) == 0 {
		b.WriteString(styleMuted.Render("  no tasks") + "\n")
	}

	prevStatus := ""
	for i, t := range m.tasks {
		// Section header on status change.
		if t.Status != prevStatus {
			if prevStatus != "" {
				b.WriteString("\n")
			}
			b.WriteString(sectionHeader(t.Status) + "\n")
			prevStatus = t.Status
		}

		line := renderTask(t)
		if i == m.cursor {
			b.WriteString(styleSelected.Render("▶ "+line) + "\n")
		} else {
			b.WriteString("  " + line + "\n")
		}
	}

	b.WriteString("\n")
	if m.mode == "filter" {
		b.WriteString(styleMsg.Render("/"+m.input+"_") + "\n")
	} else if m.message != "" {
		b.WriteString(styleMsg.Render(m.message) + "\n")
	} else {
		b.WriteString(styleHelp.Render("j/k:navigate  x:done  f:fail  /:filter  r:reload  ?:help  q:quit") + "\n")
	}

	return b.String()
}

func sectionHeader(status string) string {
	switch status {
	case "inflight":
		return styleInflight.Render("── In Flight ──")
	case "queued":
		return styleQueued.Render("── Queued ──")
	case "done":
		return styleDone.Render("── Done ──")
	case "failed":
		return styleFailed.Render("── Failed ──")
	default:
		return styleMuted.Render("── " + status + " ──")
	}
}

func renderTask(t Task) string {
	kindTag := ""
	if t.Kind == "scout" {
		kindTag = styleScout.Render("[scout] ")
	}
	id := styleMuted.Render(t.ID)
	repo := styleMuted.Render("(" + t.Repo + ")")
	title := t.Title
	if len(title) > 60 {
		title = title[:57] + "..."
	}
	return fmt.Sprintf("%s %s%s %s", id, kindTag, title, repo)
}

func helpView() string {
	return styleHeader.Render("fm-tasks TUI — keybindings") + "\n\n" +
		"  j / ↓      next task\n" +
		"  k / ↑      previous task\n" +
		"  g / G      first / last\n" +
		"  Ctrl-d/u   half-page down / up\n" +
		"  x          mark done\n" +
		"  f          mark failed\n" +
		"  /          filter by repo (Enter to apply, Esc to cancel)\n" +
		"  r          reload from database\n" +
		"  ?          this help\n" +
		"  q          quit\n\n" +
		styleHelp.Render("press any key to return")
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func cmdTUI(db *sql.DB) {
	p := tea.NewProgram(initTUI(db), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stdout, "error: tui:", err)
		os.Exit(1)
	}
}
