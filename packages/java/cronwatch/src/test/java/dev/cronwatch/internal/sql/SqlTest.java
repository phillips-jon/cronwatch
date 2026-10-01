package dev.cronwatch.internal.sql;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import org.junit.jupiter.api.Test;

/** The schema and statements, held to sql.ts's text. */
class SqlTest {
  @Test
  void prefixesFollowTheSdksRule() {
    assertEquals("cw_", Sql.tablePrefix("cw_"));
    assertEquals("_x9", Sql.tablePrefix("_x9"));
    assertEquals(
        "cronwatch: invalid table prefix \"Monitoring_\". Use lowercase letters, digits and"
            + " underscores, not starting with a digit, at most 47 characters.",
        assertThrows(IllegalArgumentException.class, () -> Sql.tablePrefix("Monitoring_"))
            .getMessage());
    assertThrows(IllegalArgumentException.class, () -> Sql.tablePrefix("9x"));
    assertThrows(IllegalArgumentException.class, () -> Sql.tablePrefix(""));
    assertThrows(IllegalArgumentException.class, () -> Sql.tablePrefix("a".repeat(48)));
    assertEquals("a".repeat(47), Sql.tablePrefix("a".repeat(47)));
  }

  @Test
  void theSchemaIsFiveStatements() {
    List<String> s = Sql.schema(Dialect.SQLITE, "cw_");
    assertEquals(5, s.size());
    assertTrue(s.get(1).contains("metrics TEXT NOT NULL DEFAULT '{}'"));
    assertTrue(
        s.get(1)
            .startsWith("\n    CREATE TABLE IF NOT EXISTS cw_runs (\n      id TEXT PRIMARY KEY,"));
  }

  @Test
  void postgresIsSqlTsTextForTextBeforeTheNumbering() {
    List<String> s = Sql.schema(Dialect.POSTGRES, "cw_");
    assertEquals(5, s.size());
    assertTrue(
        s.get(1)
            .startsWith(
                "\n    CREATE TABLE IF NOT EXISTS cw_runs (\n      seq BIGSERIAL,\n      id TEXT"
                    + " PRIMARY KEY,"));
    assertTrue(
        s.get(1).contains("started_at BIGINT NOT NULL")
            && s.get(1).contains("metrics JSONB NOT NULL DEFAULT '{}'"));
    Sql.Statements q = new Sql.Statements(Dialect.POSTGRES, "cw_");
    assertEquals("SELECT * FROM cw_jobs ORDER BY name COLLATE \"C\"", q.listJobs);
    assertEquals(
        "UPDATE cw_state SET state = ? WHERE job = ? AND CASE WHEN jsonb_typeof(state->'version')"
            + " <> 'number' THEN 0 WHEN (state->>'version')::numeric % 1 = 0 AND"
            + " (state->>'version')::numeric BETWEEN 0 AND 9007199254740991 THEN"
            + " (state->>'version')::numeric::bigint ELSE 0 END = ?",
        q.casUpdate);
    assertEquals(
        "INSERT INTO cw_state (job, state) VALUES (?, ?)\n      ON CONFLICT (job) DO UPDATE SET"
            + " state = excluded.state WHERE CASE WHEN jsonb_typeof(cw_state.state->'version') <>"
            + " 'number' THEN 0 WHEN (cw_state.state->>'version')::numeric % 1 = 0 AND"
            + " (cw_state.state->>'version')::numeric BETWEEN 0 AND 9007199254740991 THEN"
            + " (cw_state.state->>'version')::numeric::bigint ELSE 0 END = 0",
        q.casInsert);
    assertEquals(
        "SELECT * FROM cw_runs WHERE job = ? ORDER BY started_at DESC, seq DESC LIMIT ?",
        q.listRuns);
    assertTrue(q.updateRunIf(2).endsWith("WHERE id = ? AND status IN (?, ?)"));
    Sql.Statements l = new Sql.Statements(Dialect.SQLITE, "cw_");
    assertEquals(
        "UPDATE cw_state SET state = ? WHERE job = ? AND CASE WHEN NOT json_valid(state) THEN 0"
            + " WHEN json_type(state, '$.version') NOT IN ('integer', 'real') THEN 0 WHEN json_extract(state, '$.version') ="
            + " CAST(json_extract(state, '$.version') AS INTEGER) AND json_extract(state,"
            + " '$.version') BETWEEN 0 AND 9007199254740991 THEN CAST(json_extract(state,"
            + " '$.version') AS INTEGER) ELSE 0 END = ?",
        l.casUpdate);
    assertEquals(
        "SELECT * FROM cw_runs WHERE job = ? ORDER BY started_at DESC, rowid DESC LIMIT ?",
        l.listRuns);
  }
}
