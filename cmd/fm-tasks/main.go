// fm-tasks: AXI-compliant CLI task store for firstmate.
//
// Extracted from orbit/cmd/fm-tasks on 2026-06-26; orbit is retired.
// This is now a self-contained Go module living inside the firstmate repo.
// It has no dependency on any orbit package — only the standard library and
// the pure-Go SQLite driver modernc.org/sqlite (no CGO).
// Build: cd LIVE/firstmate && go build -o <dest>/fm-tasks ./cmd/fm-tasks
//
// Replaces data/backlog.md. Persists tasks in a SQLite WAL database at
// data/tasks.db with a strict schema. Subcommands: ls, get, add, start, done,
// fail, unblock, unblocked-by, meta, migrate.
//
// Error contract:
//   - all errors on stdout: "error: ..." + "help: ..."
//   - exit 0=success/no-op, 1=error, 2=usage
package main

import (
	"bufio"
	"database/sql"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

// schemaSQL is the canonical tasks table. Run on every open so a fresh DB is
// usable without an external migrate step. The CHECK constraints encode the
// 8-step contract from firstmate: kind ∈ {ship,scout}, status is the closed
// lifecycle set, blocked_by is a self-reference for the dependency DAG.
const schemaSQL = `
CREATE TABLE IF NOT EXISTS tasks (
  id              TEXT PRIMARY KEY,
  title           TEXT NOT NULL,
  repo            TEXT NOT NULL,
  kind            TEXT NOT NULL CHECK(kind IN ('ship','scout')),
  status          TEXT NOT NULL DEFAULT 'queued'
                  CHECK(status IN ('inflight','queued','done','failed')),
  blocked_by      TEXT REFERENCES tasks(id),
  blocked_reason  TEXT,
  pr_url          TEXT,
  report_path     TEXT,
  added_at        TEXT NOT NULL DEFAULT (datetime('now')),
  started_at      TEXT,
  done_at         TEXT,
  meta            TEXT
);
CREATE INDEX IF NOT EXISTS idx_tasks_status     ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_repo       ON tasks(repo);
CREATE INDEX IF NOT EXISTS idx_tasks_blocked_by ON tasks(blocked_by);
PRAGMA journal_mode=WAL;
`

// Task mirrors the tasks table row.
type Task struct {
	ID            string
	Title         string
	Repo          string
	Kind          string
	Status        string
	BlockedBy     sql.NullString
	BlockedReason sql.NullString
	PRURL         sql.NullString
	ReportPath    sql.NullString
	AddedAt       string
	StartedAt     sql.NullString
	DoneAt        sql.NullString
	Meta          sql.NullString
}

// exitCode: 0=ok, 1=error, 2=usage. Errors print "error: <msg>" + "help: <hint>"
// on stdout and return non-zero.
func dieUsage(format string, args ...any) {
	fmt.Fprintf(os.Stdout, "usage: fm-tasks %s\n", os.Args[1])
	fmt.Fprintf(os.Stdout, "error: "+format+"\n", args...)
	os.Exit(2)
}

func dieError(err error, help string) {
	fmt.Fprintf(os.Stdout, "error: %v\n", err)
	if help != "" {
		fmt.Fprintf(os.Stdout, "help: %s\n", help)
	}
	os.Exit(1)
}

func dieMsg(msg, help string) {
	fmt.Fprintf(os.Stdout, "error: %s\n", msg)
	if help != "" {
		fmt.Fprintf(os.Stdout, "help: %s\n", help)
	}
	os.Exit(1)
}

// openDB opens data/tasks.db relative to the current working directory. It
// creates the parent dir, runs the schema, and returns a ready handle.
func openDB() *sql.DB {
	dbPath := filepath.Join("data", "tasks.db")
	if err := os.MkdirAll(filepath.Dir(dbPath), 0o755); err != nil {
		dieError(err, "ensure ./data/ is writable")
	}
	db, err := sql.Open("sqlite", dbPath+"?_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)")
	if err != nil {
		dieError(err, "check modernc.org/sqlite driver registration")
	}
	if _, err := db.Exec(schemaSQL); err != nil {
		dieError(err, "schema bootstrap failed")
	}
	return db
}

// fieldsDefault is the default projection for `ls`.
var fieldsDefault = []string{"id", "repo", "kind", "status"}

// allFields is the complete set of printable fields, in canonical order.
var allFields = []string{
	"id", "title", "repo", "kind", "status",
	"blocked_by", "blocked_reason", "pr_url", "report_path",
	"added_at", "started_at", "done_at", "meta",
}

// parseFields normalizes a comma-separated field list against allFields.
// Returns the default set if empty. Errors if a token is not a known field.
func parseFields(spec string) ([]string, error) {
	if strings.TrimSpace(spec) == "" {
		out := make([]string, len(fieldsDefault))
		copy(out, fieldsDefault)
		return out, nil
	}
	known := make(map[string]bool, len(allFields))
	for _, f := range allFields {
		known[f] = true
	}
	parts := strings.Split(spec, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		f := strings.TrimSpace(p)
		if f == "" {
			continue
		}
		if !known[f] {
			return nil, fmt.Errorf("unknown field %q (known: %s)", f, strings.Join(allFields, ","))
		}
		out = append(out, f)
	}
	if len(out) == 0 {
		out = make([]string, len(fieldsDefault))
		copy(out, fieldsDefault)
	}
	return out, nil
}

// fieldValue returns the value of a column for output.
func fieldValue(t *Task, field string) (string, bool) {
	switch field {
	case "id":
		return t.ID, true
	case "title":
		return t.Title, true
	case "repo":
		return t.Repo, true
	case "kind":
		return t.Kind, true
	case "status":
		return t.Status, true
	case "blocked_by":
		if t.BlockedBy.Valid {
			return t.BlockedBy.String, true
		}
	case "blocked_reason":
		if t.BlockedReason.Valid {
			return t.BlockedReason.String, true
		}
	case "pr_url":
		if t.PRURL.Valid {
			return t.PRURL.String, true
		}
	case "report_path":
		if t.ReportPath.Valid {
			return t.ReportPath.String, true
		}
	case "added_at":
		return t.AddedAt, true
	case "started_at":
		if t.StartedAt.Valid {
			return t.StartedAt.String, true
		}
	case "done_at":
		if t.DoneAt.Valid {
			return t.DoneAt.String, true
		}
	case "meta":
		if t.Meta.Valid {
			return t.Meta.String, true
		}
	}
	return "", false
}

// cmdLs: fm-tasks ls [--status S] [--repo R] [--fields f1,f2,...]
func cmdLs(db *sql.DB, args []string) {
	fs := flag.NewFlagSet("ls", flag.ContinueOnError)
	fs.SetOutput(os.Stdout)
	status := fs.String("status", "", "filter by status (inflight|queued|done|failed)")
	repo := fs.String("repo", "", "filter by repo")
	fields := fs.String("fields", "", "comma-separated fields to print (default: id,repo,kind,status)")
	if err := fs.Parse(args); err != nil {
		dieUsage("--status, --repo, --fields are optional")
	}

	fieldList, err := parseFields(*fields)
	if err != nil {
		dieError(err, "valid fields: "+strings.Join(allFields, ","))
	}

	// Build a parameterized query. We do not interpolate filter values into the
	// SQL string.
	q := "SELECT id,title,repo,kind,status,blocked_by,blocked_reason,pr_url,report_path,added_at,started_at,done_at,meta FROM tasks WHERE 1=1"
	var params []any
	if *status != "" {
		q += " AND status = ?"
		params = append(params, *status)
	}
	if *repo != "" {
		q += " AND repo = ?"
		params = append(params, *repo)
	}
	q += " ORDER BY added_at ASC, id ASC"

	rows, err := db.Query(q, params...)
	if err != nil {
		dieError(err, "query tasks")
	}
	defer rows.Close()

	var tasks []Task
	for rows.Next() {
		var t Task
		if err := rows.Scan(&t.ID, &t.Title, &t.Repo, &t.Kind, &t.Status,
			&t.BlockedBy, &t.BlockedReason, &t.PRURL, &t.ReportPath,
			&t.AddedAt, &t.StartedAt, &t.DoneAt, &t.Meta); err != nil {
			dieError(err, "scan row")
		}
		tasks = append(tasks, t)
	}
	if err := rows.Err(); err != nil {
		dieError(err, "iterate rows")
	}

	statusLabel := *status
	if statusLabel == "" {
		statusLabel = "all"
	}
	if len(tasks) == 0 {
		fmt.Printf("tasks: 0 %s tasks\n", statusLabel)
		return
	}

	header := strings.Join(fieldList, ",")
	fmt.Printf("tasks[%d]{%s}:\n", len(tasks), header)
	for i := range tasks {
		vals := make([]string, 0, len(fieldList))
		for _, f := range fieldList {
			if v, ok := fieldValue(&tasks[i], f); ok {
				vals = append(vals, v)
			} else {
				vals = append(vals, "")
			}
		}
		fmt.Printf("  %s\n", strings.Join(vals, ","))
	}
	fmt.Printf("count: %d %s tasks\n", len(tasks), statusLabel)
}

// cmdGet: fm-tasks get <id>
func cmdGet(db *sql.DB, args []string) {
	if len(args) < 1 {
		dieUsage("<id> required")
	}
	id := args[0]
	row := db.QueryRow(`SELECT id,title,repo,kind,status,blocked_by,blocked_reason,pr_url,report_path,added_at,started_at,done_at,meta FROM tasks WHERE id = ?`, id)
	var t Task
	if err := row.Scan(&t.ID, &t.Title, &t.Repo, &t.Kind, &t.Status,
		&t.BlockedBy, &t.BlockedReason, &t.PRURL, &t.ReportPath,
		&t.AddedAt, &t.StartedAt, &t.DoneAt, &t.Meta); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			dieMsg("task not found: "+id, "add it first with: fm-tasks add --id <id> ...")
		}
		dieError(err, "query task")
	}
	fmt.Println("task:")
	fmt.Printf("  id: %s\n", t.ID)
	fmt.Printf("  title: %s\n", t.Title)
	fmt.Printf("  repo: %s\n", t.Repo)
	fmt.Printf("  kind: %s\n", t.Kind)
	fmt.Printf("  status: %s\n", t.Status)
	if t.BlockedBy.Valid {
		fmt.Printf("  blocked_by: %s\n", t.BlockedBy.String)
	}
	if t.PRURL.Valid {
		fmt.Printf("  pr_url: %s\n", t.PRURL.String)
	}
	fmt.Printf("  added_at: %s\n", t.AddedAt)
	if t.Meta.Valid {
		fmt.Printf("  meta: %s\n", t.Meta.String)
	}
}

// cmdAdd: fm-tasks add --id <id> --repo <r> --kind ship|scout --title "..." [--blocked-by <id>] [--blocked-reason "..."] [--meta '{}']
func cmdAdd(db *sql.DB, args []string) {
	fs := flag.NewFlagSet("add", flag.ContinueOnError)
	fs.SetOutput(os.Stdout)
	id := fs.String("id", "", "task id (required)")
	repo := fs.String("repo", "", "repo path (required)")
	kind := fs.String("kind", "", "ship|scout (required)")
	title := fs.String("title", "", "title (required)")
	blockedBy := fs.String("blocked-by", "", "id of blocking task")
	blockedReason := fs.String("blocked-reason", "", "reason blocked")
	meta := fs.String("meta", "", "JSON meta blob")
	if err := fs.Parse(args); err != nil {
		dieUsage("--id, --repo, --kind, --title are required")
	}
	if *id == "" || *repo == "" || *kind == "" || *title == "" {
		dieUsage("--id, --repo, --kind, --title are all required")
	}
	if *kind != "ship" && *kind != "scout" {
		dieMsg("kind must be ship or scout", "use --kind ship or --kind scout")
	}
	if *meta != "" && !json.Valid([]byte(*meta)) {
		dieMsg("meta must be valid JSON", "pass a JSON object like --meta '{\"k\":\"v\"}'")
	}

	// Idempotent: if a row with the same id exists and titles match, no-op.
	var existingTitle string
	err := db.QueryRow(`SELECT title FROM tasks WHERE id = ?`, *id).Scan(&existingTitle)
	if err == nil {
		if existingTitle == *title {
			fmt.Printf("task: %s already exists (no-op)\n", *id)
			return
		}
		dieMsg(*id+" exists with different title", "delete the row or pick a new id")
	}
	if !errors.Is(err, sql.ErrNoRows) {
		dieError(err, "lookup existing task")
	}

	var bb any
	if *blockedBy != "" {
		bb = *blockedBy
	}
	var br any
	if *blockedReason != "" {
		br = *blockedReason
	}
	var m any
	if *meta != "" {
		m = *meta
	}
	if _, err := db.Exec(
		`INSERT INTO tasks (id, title, repo, kind, blocked_by, blocked_reason, meta) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		*id, *title, *repo, *kind, bb, br, m,
	); err != nil {
		dieError(err, "insert task")
	}
	fmt.Printf("task: %s added (queued, %s, %s)\n", *id, *repo, *kind)
}

// cmdStart: fm-tasks start <id> [--meta '{}']
func cmdStart(db *sql.DB, args []string) {
	fs := flag.NewFlagSet("start", flag.ContinueOnError)
	fs.SetOutput(os.Stdout)
	meta := fs.String("meta", "", "optional JSON meta blob to merge")
	if err := fs.Parse(args); err != nil {
		dieUsage("<id> required")
	}
	rest := fs.Args()
	if len(rest) < 1 {
		dieUsage("<id> required")
	}
	id := rest[0]
	if *meta != "" && !json.Valid([]byte(*meta)) {
		dieMsg("meta must be valid JSON", "pass a JSON object")
	}

	// Status guard: only queued → inflight is allowed.
	var status string
	if err := db.QueryRow(`SELECT status FROM tasks WHERE id = ?`, id).Scan(&status); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			dieMsg("task not found: "+id, "add it first with: fm-tasks add ...")
		}
		dieError(err, "lookup task")
	}
	if status == "inflight" {
		fmt.Printf("task: %s already inflight (no-op)\n", id)
		return
	}
	if status != "queued" {
		dieMsg(fmt.Sprintf("cannot start task in status %q", status),
			"only queued tasks can be started")
	}

	// Blocked guard: cannot start while blocked_by is set.
	var blockedBy sql.NullString
	if err := db.QueryRow(`SELECT blocked_by FROM tasks WHERE id = ?`, id).Scan(&blockedBy); err != nil {
		dieError(err, "lookup blocked_by")
	}
	if blockedBy.Valid && blockedBy.String != "" {
		dieMsg("task is blocked by "+blockedBy.String,
			"run: fm-tasks unblock "+id+" after the dependency is done")
	}

	// Optional meta merge.
	if *meta != "" {
		mergeMeta(db, id, *meta)
	}

	if _, err := db.Exec(
		`UPDATE tasks SET status='inflight', started_at=datetime('now') WHERE id = ? AND status='queued'`,
		id,
	); err != nil {
		dieError(err, "update status")
	}
	fmt.Printf("task: %s started (inflight)\n", id)
}

// cmdDone: fm-tasks done <id> [--pr <url>] [--report <path>] [--local]
func cmdDone(db *sql.DB, args []string) {
	fs := flag.NewFlagSet("done", flag.ContinueOnError)
	fs.SetOutput(os.Stdout)
	pr := fs.String("pr", "", "PR URL")
	report := fs.String("report", "", "report path")
	local := fs.Bool("local", false, "local completion (no PR)")
	if err := fs.Parse(args); err != nil {
		dieUsage("<id> required")
	}
	rest := fs.Args()
	if len(rest) < 1 {
		dieUsage("<id> required")
	}
	id := rest[0]

	if !*local && *pr == "" {
		dieMsg("done requires --pr <url> or --local", "pass --pr https://github.com/... or --local")
	}

	// Status guard: only inflight → done is allowed.
	var status string
	if err := db.QueryRow(`SELECT status FROM tasks WHERE id = ?`, id).Scan(&status); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			dieMsg("task not found: "+id, "add it first with: fm-tasks add ...")
		}
		dieError(err, "lookup task")
	}
	if status == "done" {
		fmt.Printf("task: %s already done (no-op)\n", id)
		return
	}
	if status != "inflight" {
		dieMsg(fmt.Sprintf("cannot complete task in status %q", status),
			"only inflight tasks can be done; start it first")
	}

	var prArg any
	if *pr != "" {
		prArg = *pr
	}
	var reportArg any
	if *report != "" {
		reportArg = *report
	}
	if _, err := db.Exec(
		`UPDATE tasks SET status='done', done_at=datetime('now'), pr_url=COALESCE(?, pr_url), report_path=COALESCE(?, report_path) WHERE id = ? AND status='inflight'`,
		prArg, reportArg, id,
	); err != nil {
		dieError(err, "update status")
	}
	fmt.Printf("task: %s done\n", id)
}

// cmdFail: fm-tasks fail <id> [--reason "..."]
func cmdFail(db *sql.DB, args []string) {
	fs := flag.NewFlagSet("fail", flag.ContinueOnError)
	fs.SetOutput(os.Stdout)
	reason := fs.String("reason", "", "failure reason (stored in meta.fail_reason)")
	if err := fs.Parse(args); err != nil {
		dieUsage("<id> required")
	}
	rest := fs.Args()
	if len(rest) < 1 {
		dieUsage("<id> required")
	}
	id := rest[0]

	var status string
	if err := db.QueryRow(`SELECT status FROM tasks WHERE id = ?`, id).Scan(&status); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			dieMsg("task not found: "+id, "add it first with: fm-tasks add ...")
		}
		dieError(err, "lookup task")
	}
	if status == "failed" {
		fmt.Printf("task: %s already failed (no-op)\n", id)
		return
	}
	if status == "done" {
		dieMsg("cannot fail a done task", "done is terminal; create a follow-up task instead")
	}

	// Persist reason into meta as a top-level field. We use a single key
	// "fail_reason" to keep the merge deterministic and inspectable.
	if *reason != "" {
		payload := map[string]any{"fail_reason": *reason}
		buf, _ := json.Marshal(payload)
		mergeMeta(db, id, string(buf))
	}

	if _, err := db.Exec(
		`UPDATE tasks SET status='failed', done_at=datetime('now') WHERE id = ? AND status IN ('queued','inflight')`,
		id,
	); err != nil {
		dieError(err, "update status")
	}
	fmt.Printf("task: %s failed\n", id)
}

// cmdUnblock: fm-tasks unblock <id>
func cmdUnblock(db *sql.DB, args []string) {
	if len(args) < 1 {
		dieUsage("<id> required")
	}
	id := args[0]

	var prev sql.NullString
	if err := db.QueryRow(`SELECT blocked_by FROM tasks WHERE id = ?`, id).Scan(&prev); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			dieMsg("task not found: "+id, "add it first with: fm-tasks add ...")
		}
		dieError(err, "lookup task")
	}
	if !prev.Valid || prev.String == "" {
		fmt.Printf("task: %s not blocked (no-op)\n", id)
		return
	}
	if _, err := db.Exec(
		`UPDATE tasks SET blocked_by=NULL, blocked_reason=NULL WHERE id = ?`,
		id,
	); err != nil {
		dieError(err, "clear blocked_by")
	}
	fmt.Printf("task: %s unblocked (was blocked by %s)\n", id, prev.String)
}

// cmdUnblockedBy: fm-tasks unblocked-by <id>
func cmdUnblockedBy(db *sql.DB, args []string) {
	if len(args) < 1 {
		dieUsage("<id> required")
	}
	id := args[0]

	rows, err := db.Query(
		`SELECT id,title,repo,kind,status,blocked_by,blocked_reason,pr_url,report_path,added_at,started_at,done_at,meta
         FROM tasks WHERE blocked_by = ? ORDER BY added_at ASC, id ASC`, id)
	if err != nil {
		dieError(err, "query dependents")
	}
	defer rows.Close()

	fieldList := []string{"id", "repo", "kind", "title"}
	var tasks []Task
	for rows.Next() {
		var t Task
		if err := rows.Scan(&t.ID, &t.Title, &t.Repo, &t.Kind, &t.Status,
			&t.BlockedBy, &t.BlockedReason, &t.PRURL, &t.ReportPath,
			&t.AddedAt, &t.StartedAt, &t.DoneAt, &t.Meta); err != nil {
			dieError(err, "scan row")
		}
		tasks = append(tasks, t)
	}
	if err := rows.Err(); err != nil {
		dieError(err, "iterate rows")
	}

	if len(tasks) == 0 {
		fmt.Printf("tasks: 0 tasks unblocked by %s\n", id)
		return
	}
	header := strings.Join(fieldList, ",")
	fmt.Printf("tasks[%d]{%s}:\n", len(tasks), header)
	for i := range tasks {
		vals := make([]string, 0, len(fieldList))
		for _, f := range fieldList {
			if v, ok := fieldValue(&tasks[i], f); ok {
				vals = append(vals, v)
			} else {
				vals = append(vals, "")
			}
		}
		fmt.Printf("  %s\n", strings.Join(vals, ","))
	}
	fmt.Printf("count: %d tasks unblocked\n", len(tasks))
}

// cmdMeta: fm-tasks meta <id> --set '{"key":"val"}'
func cmdMeta(db *sql.DB, args []string) {
	fs := flag.NewFlagSet("meta", flag.ContinueOnError)
	fs.SetOutput(os.Stdout)
	set := fs.String("set", "", "JSON object to merge into meta (required)")
	if err := fs.Parse(args); err != nil {
		dieUsage("<id> --set '<json>'")
	}
	rest := fs.Args()
	if len(rest) < 1 {
		dieUsage("<id> required")
	}
	id := rest[0]
	if *set == "" {
		dieUsage("--set <json> required")
	}
	if !json.Valid([]byte(*set)) {
		dieMsg("--set must be a valid JSON object", "pass JSON like --set '{\"k\":\"v\"}'")
	}

	// Validate it's an object (not array/scalar): scan into a map.
	var probe map[string]any
	if err := json.Unmarshal([]byte(*set), &probe); err != nil {
		dieMsg("--set must be a JSON object", "pass JSON like --set '{\"k\":\"v\"}'")
	}

	var status string
	if err := db.QueryRow(`SELECT status FROM tasks WHERE id = ?`, id).Scan(&status); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			dieMsg("task not found: "+id, "add it first with: fm-tasks add ...")
		}
		dieError(err, "lookup task")
	}

	mergeMeta(db, id, *set)
	fmt.Printf("task: %s meta updated\n", id)
}

// mergeMeta merges a JSON object into the meta column of a row. New keys win.
// If the existing meta is not a JSON object, it is replaced.
func mergeMeta(db *sql.DB, id, payload string) {
	var existing sql.NullString
	if err := db.QueryRow(`SELECT meta FROM tasks WHERE id = ?`, id).Scan(&existing); err != nil {
		dieError(err, "lookup meta")
	}
	merged := map[string]any{}
	if existing.Valid && strings.TrimSpace(existing.String) != "" {
		var prev map[string]any
		if err := json.Unmarshal([]byte(existing.String), &prev); err == nil {
			merged = prev
		}
	}
	var patch map[string]any
	if err := json.Unmarshal([]byte(payload), &patch); err != nil {
		dieMsg("invalid meta JSON", "pass a JSON object")
	}
	for k, v := range patch {
		merged[k] = v
	}
	buf, err := json.Marshal(merged)
	if err != nil {
		dieError(err, "marshal merged meta")
	}
	if _, err := db.Exec(`UPDATE tasks SET meta = ? WHERE id = ?`, string(buf), id); err != nil {
		dieError(err, "write meta")
	}
}

// cmdMigrate: fm-tasks migrate --from <path> [--dry-run]
//
// Parses data/backlog.md and inserts tasks. Recognized sections:
//
//	## In flight  → status=inflight
//	## Queued     → status=queued
//	## Done       → status=done
//
// Within each section, lines of the form `- <id> [kind] <title> [block:<id>]`
// are parsed. The default kind is "ship".
func cmdMigrate(db *sql.DB, args []string) {
	fs := flag.NewFlagSet("migrate", flag.ContinueOnError)
	fs.SetOutput(os.Stdout)
	from := fs.String("from", "", "path to backlog.md (required)")
	dryRun := fs.Bool("dry-run", false, "print actions without writing")
	if err := fs.Parse(args); err != nil {
		dieUsage("--from <path> [--dry-run]")
	}
	if *from == "" {
		dieUsage("--from <path> required")
	}

	f, err := os.Open(*from)
	if err != nil {
		dieError(err, "open backlog file")
	}
	defer f.Close()

	entries, err := parseBacklog(f)
	if err != nil {
		dieError(err, "parse backlog.md")
	}

	inserted := 0
	for _, e := range entries {
		// Skip if already present with same title.
		var existingTitle string
		err := db.QueryRow(`SELECT title FROM tasks WHERE id = ?`, e.ID).Scan(&existingTitle)
		switch {
		case err == nil:
			if existingTitle == e.Title {
				continue
			}
			dieMsg(e.ID+" exists with different title", "remove it or pick a new id")
		case errors.Is(err, sql.ErrNoRows):
			// fall through to insert
		default:
			dieError(err, "lookup existing task")
		}
		if *dryRun {
			fmt.Printf("insert,%s,%s\n", e.ID, e.Status)
			continue
		}
		var bb any
		if e.BlockedBy != "" {
			bb = e.BlockedBy
		}
		if _, err := db.Exec(
			`INSERT INTO tasks (id, title, repo, kind, status, blocked_by, added_at, started_at, done_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			e.ID, e.Title, e.Repo, e.Kind, e.Status, bb, e.AddedAt, e.StartedAt, e.DoneAt,
		); err != nil {
			dieError(err, "insert task "+e.ID)
		}
		inserted++
	}
	if *dryRun {
		return
	}
	fmt.Printf("migrate: %d tasks inserted\n", inserted)
}

// backlogEntry is a parsed row from data/backlog.md.
type backlogEntry struct {
	ID        string
	Title     string
	Repo      string
	Kind      string
	Status    string
	BlockedBy string
	AddedAt   string
	StartedAt string
	DoneAt    string
}

// parseBacklog walks the markdown and pulls out sectioned task lists. The
// grammar is intentionally narrow: a line starting with `- ` inside a known
// section becomes a task; everything else is ignored.
func parseBacklog(f *os.File) ([]backlogEntry, error) {
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 1<<16), 1<<20)

	const (
		secNone = ""
		secInfl = "inflight"
		secQueu = "queued"
		secDone = "done"
	)
	cur := secNone
	now := time.Now().UTC().Format("2006-01-02 15:04:05")

	var out []backlogEntry
	for scanner.Scan() {
		line := strings.TrimRight(scanner.Text(), " \t\r")
		trimmed := strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(trimmed, "## "):
			header := strings.ToLower(strings.TrimSpace(strings.TrimPrefix(trimmed, "## ")))
			switch {
			case strings.Contains(header, "in flight") || strings.Contains(header, "in-flight") || strings.Contains(header, "inflight"):
				cur = secInfl
			case strings.Contains(header, "queued") || strings.Contains(header, "queue"):
				cur = secQueu
			case strings.Contains(header, "done"):
				cur = secDone
			default:
				cur = secNone
			}
			continue
		case !strings.HasPrefix(trimmed, "- "):
			continue
		}
		if cur == secNone {
			continue
		}
		rest := strings.TrimSpace(strings.TrimPrefix(trimmed, "- "))
		e := parseBacklogLine(rest, cur, now)
		if e == nil {
			continue
		}
		out = append(out, *e)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	// Stable order: inflight first, then queued, then done, each by id.
	sort.SliceStable(out, func(i, j int) bool {
		ri := sectionRank(out[i].Status)
		rj := sectionRank(out[j].Status)
		if ri != rj {
			return ri < rj
		}
		return out[i].ID < out[j].ID
	})
	return out, nil
}

func sectionRank(s string) int {
	switch s {
	case "inflight":
		return 0
	case "queued":
		return 1
	case "done":
		return 2
	}
	return 3
}

// parseBacklogLine extracts a single task from one bullet line. The line has
// the shape `<id> [kind] <title> [block:<id>]` with optional trailing notes.
// We are intentionally permissive on title whitespace; we are strict on the id
// (lowercase alnum + dash/underscore) so it round-trips into the DB.
func parseBacklogLine(line, sectionStatus, now string) *backlogEntry {
	if line == "" {
		return nil
	}
	// Pull off the id (first whitespace-delimited token).
	sp := strings.IndexAny(line, " \t")
	if sp <= 0 {
		return nil
	}
	id := line[:sp]
	if !isValidID(id) {
		return nil
	}
	rest := strings.TrimSpace(line[sp:])

	// Optional kind: literal "ship" or "scout" appearing as a standalone token.
	kind := "ship"
	if rest != "" {
		next := strings.IndexAny(rest, " \t")
		var head string
		if next < 0 {
			head = rest
		} else {
			head = rest[:next]
		}
		if head == "ship" || head == "scout" {
			kind = head
			if next >= 0 {
				rest = strings.TrimSpace(rest[next:])
			} else {
				rest = ""
			}
		}
	}

	// Optional block:<id> at the end of the line.
	var blockedBy string
	if i := strings.LastIndex(rest, "block:"); i >= 0 {
		tail := strings.TrimSpace(rest[i+len("block:"):])
		// The blocker id ends at the first whitespace.
		if sp := strings.IndexAny(tail, " \t"); sp >= 0 {
			tail = tail[:sp]
		}
		if isValidID(tail) {
			blockedBy = tail
		}
		// Strip the annotation from the title.
		rest = strings.TrimSpace(rest[:i])
	}

	if rest == "" {
		// Title cannot be empty.
		return nil
	}

	e := &backlogEntry{
		ID:        id,
		Title:     rest,
		Repo:      ".",
		Kind:      kind,
		Status:    sectionStatus,
		BlockedBy: blockedBy,
		AddedAt:   now,
	}
	if sectionStatus == "inflight" {
		e.StartedAt = now
	}
	if sectionStatus == "done" {
		e.StartedAt = now
		e.DoneAt = now
	}
	return e
}

// isValidID keeps the migration parser honest: a backlog id is the same kind
// of slug we'd accept as a firstmate task id.
func isValidID(s string) bool {
	if s == "" {
		return false
	}
	for i, r := range s {
		switch {
		case r >= 'a' && r <= 'z':
		case r >= 'A' && r <= 'Z':
		case r >= '0' && r <= '9':
		case r == '-' || r == '_' || r == '.':
		case r == '/' && i > 0:
		default:
			return false
		}
	}
	return true
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stdout, "usage: fm-tasks <subcommand> [args]")
		fmt.Fprintln(os.Stdout, "subcommands: ls, get, add, start, done, fail, unblock, unblocked-by, meta, migrate")
		os.Exit(2)
	}
	sub := os.Args[1]
	rest := os.Args[2:]

	db := openDB()
	defer db.Close()

	switch sub {
	case "ls":
		cmdLs(db, rest)
	case "get":
		cmdGet(db, rest)
	case "add":
		cmdAdd(db, rest)
	case "start":
		cmdStart(db, rest)
	case "done":
		cmdDone(db, rest)
	case "fail":
		cmdFail(db, rest)
	case "unblock":
		cmdUnblock(db, rest)
	case "unblocked-by":
		cmdUnblockedBy(db, rest)
	case "meta":
		cmdMeta(db, rest)
	case "migrate":
		cmdMigrate(db, rest)
	default:
		fmt.Fprintf(os.Stdout, "usage: fm-tasks <subcommand> [args]\n")
		fmt.Fprintf(os.Stdout, "error: unknown subcommand %q\n", sub)
		fmt.Fprintln(os.Stdout, "help: valid subcommands: ls, get, add, start, done, fail, unblock, unblocked-by, meta, migrate")
		os.Exit(2)
	}
}
