package sqlstore

import "testing"

// The compare-and-set statements are sql.ts's byte for byte (Postgres and
// SQLite), and the MySQL text is the one every port's MySQL store shares. A
// state's version counts as the SDK's stateVersion() reads it: a whole
// number from 0 to 2^53 - 1, else 0, never a failed cast.
func TestCompareAndSetStatementsMatchTheSDK(t *testing.T) {
	cases := []struct {
		dialect   Dialect
		got, want string
	}{
		{Postgres, newStatements(Postgres, "cronwatch_").casUpdate,
			`UPDATE cronwatch_state SET state = $1 WHERE job = $2 AND CASE WHEN jsonb_typeof(state->'version') <> 'number' THEN 0 WHEN (state->>'version')::numeric % 1 = 0 AND (state->>'version')::numeric BETWEEN 0 AND 9007199254740991 THEN (state->>'version')::numeric::bigint ELSE 0 END = $3`},
		{Postgres, newStatements(Postgres, "cronwatch_").casInsert,
			"INSERT INTO cronwatch_state (job, state) VALUES ($1, $2)\n      ON CONFLICT (job) DO UPDATE SET state = excluded.state WHERE CASE WHEN jsonb_typeof(cronwatch_state.state->'version') <> 'number' THEN 0 WHEN (cronwatch_state.state->>'version')::numeric % 1 = 0 AND (cronwatch_state.state->>'version')::numeric BETWEEN 0 AND 9007199254740991 THEN (cronwatch_state.state->>'version')::numeric::bigint ELSE 0 END = 0"},
		{SQLite, newStatements(SQLite, "cronwatch_").casUpdate,
			`UPDATE cronwatch_state SET state = ? WHERE job = ? AND CASE WHEN NOT json_valid(state) THEN 0 WHEN json_type(state, '$.version') NOT IN ('integer', 'real') THEN 0 WHEN json_extract(state, '$.version') = CAST(json_extract(state, '$.version') AS INTEGER) AND json_extract(state, '$.version') BETWEEN 0 AND 9007199254740991 THEN CAST(json_extract(state, '$.version') AS INTEGER) ELSE 0 END = ?`},
		{SQLite, newStatements(SQLite, "cronwatch_").casInsert,
			"INSERT INTO cronwatch_state (job, state) VALUES (?, ?)\n      ON CONFLICT (job) DO UPDATE SET state = excluded.state WHERE CASE WHEN NOT json_valid(cronwatch_state.state) THEN 0 WHEN json_type(cronwatch_state.state, '$.version') NOT IN ('integer', 'real') THEN 0 WHEN json_extract(cronwatch_state.state, '$.version') = CAST(json_extract(cronwatch_state.state, '$.version') AS INTEGER) AND json_extract(cronwatch_state.state, '$.version') BETWEEN 0 AND 9007199254740991 THEN CAST(json_extract(cronwatch_state.state, '$.version') AS INTEGER) ELSE 0 END = 0"},
		{MySQL, newStatements(MySQL, "cronwatch_").casUpdate,
			`UPDATE cronwatch_state SET state = ? WHERE job = ? AND CASE WHEN JSON_TYPE(JSON_EXTRACT(state, '$.version')) NOT IN ('INTEGER', 'UNSIGNED INTEGER', 'DOUBLE', 'DECIMAL') THEN 0 WHEN JSON_EXTRACT(state, '$.version') + 0 = FLOOR(JSON_EXTRACT(state, '$.version') + 0) AND JSON_EXTRACT(state, '$.version') + 0 BETWEEN 0 AND 9007199254740991 THEN CAST(JSON_EXTRACT(state, '$.version') + 0 AS SIGNED) ELSE 0 END = ?`},
		{MySQL, newStatements(MySQL, "cronwatch_").casFromZero,
			`UPDATE cronwatch_state SET state = ? WHERE job = ? AND CASE WHEN JSON_TYPE(JSON_EXTRACT(state, '$.version')) NOT IN ('INTEGER', 'UNSIGNED INTEGER', 'DOUBLE', 'DECIMAL') THEN 0 WHEN JSON_EXTRACT(state, '$.version') + 0 = FLOOR(JSON_EXTRACT(state, '$.version') + 0) AND JSON_EXTRACT(state, '$.version') + 0 BETWEEN 0 AND 9007199254740991 THEN CAST(JSON_EXTRACT(state, '$.version') + 0 AS SIGNED) ELSE 0 END = 0`},
	}
	for i, c := range cases {
		if c.got != c.want {
			t.Errorf("%d (%s):\n got %s\nwant %s", i, c.dialect, c.got, c.want)
		}
	}
}
