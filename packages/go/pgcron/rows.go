package pgcron

// Rows as any driver hands them back: ids as int64 or text, booleans as
// bool or "t", timestamps as time.Time or Postgres's text.

import (
	"context"
	"strconv"
	"strings"
	"time"
)

// query runs a query and reads every row as column name to value.
func query(ctx context.Context, db Querier, sql string, args ...any) ([]map[string]any, error) {
	rows, err := db.QueryContext(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	names, err := rows.Columns()
	if err != nil {
		return nil, err
	}
	var out []map[string]any
	for rows.Next() {
		values := make([]any, len(names))
		pointers := make([]any, len(names))
		for i := range values {
			pointers[i] = &values[i]
		}
		if err := rows.Scan(pointers...); err != nil {
			return nil, err
		}
		row := make(map[string]any, len(names))
		for i, name := range names {
			row[name] = values[i]
		}
		out = append(out, row)
	}
	return out, rows.Err()
}

// text is a text column's value, and false for NULL.
func text(v any) (string, bool) {
	switch t := v.(type) {
	case string:
		return t, true
	case []byte:
		return string(t), true
	case nil:
		return "", false
	}
	return "", false
}

// integer is a bigint column's value, however the driver sends it.
func integer(v any) int64 {
	switch t := v.(type) {
	case int64:
		return t
	case int32:
		return int64(t)
	case int:
		return int64(t)
	case float64:
		return int64(t)
	}
	if s, ok := text(v); ok {
		n, _ := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
		return n
	}
	return 0
}

// boolean is a boolean column's value, however the driver sends it.
func boolean(v any) bool {
	switch t := v.(type) {
	case bool:
		return t
	case int64:
		return t != 0
	}
	s, _ := text(v)
	switch strings.ToLower(s) {
	case "t", "true", "1", "yes", "on":
		return true
	}
	return false
}

// timestampLayouts are the forms Postgres writes a timestamp with time
// zone in as text, and the ISO form.
var timestampLayouts = []string{
	"2006-01-02 15:04:05.999999999-07",
	"2006-01-02 15:04:05.999999999-07:00",
	"2006-01-02 15:04:05.999999999-07:00:00",
	time.RFC3339Nano,
	"2006-01-02 15:04:05.999999999",
}

// timestamp is a timestamp column's value, nil for NULL.
func timestamp(v any) *time.Time {
	if t, ok := v.(time.Time); ok {
		return &t
	}
	s, ok := text(v)
	if !ok {
		return nil
	}
	for _, layout := range timestampLayouts {
		if t, err := time.Parse(layout, strings.TrimSpace(s)); err == nil {
			return &t
		}
	}
	return nil
}

func jobOf(r map[string]any) Job {
	j := Job{JobID: integer(r["jobid"]), Active: boolean(r["active"])}
	if name, ok := text(r["jobname"]); ok {
		j.JobName = &name
	}
	j.Schedule, _ = text(r["schedule"])
	j.Database, _ = text(r["database"])
	j.Username, _ = text(r["username"])
	return j
}

func rowOf(r map[string]any) Row {
	row := Row{RunID: integer(r["runid"]), JobID: integer(r["jobid"]), StartTime: timestamp(r["start_time"]), EndTime: timestamp(r["end_time"])}
	row.Status, _ = text(r["status"])
	if message, ok := text(r["return_message"]); ok {
		row.ReturnMessage = &message
	}
	return row
}
