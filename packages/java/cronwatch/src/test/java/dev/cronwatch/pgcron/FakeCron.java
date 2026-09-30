package dev.cronwatch.pgcron;

import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import org.jspecify.annotations.Nullable;

/**
 * {@code cron.job} and {@code cron.job_run_details} in memory, answering the source's queries as
 * the SDK's {@code fakeCron()} does: ids as text, as some drivers hand a {@code bigint} back, and
 * times as {@link Instant}s.
 */
final class FakeCron implements PgCron.Query {
  /** A row of {@code cron.job}, changed in place by the tests. */
  static final class Job {
    final long jobId;
    @Nullable String jobName;
    final String schedule;
    boolean active;

    Job(long jobId, @Nullable String jobName, String schedule, boolean active) {
      this.jobId = jobId;
      this.jobName = jobName;
      this.schedule = schedule;
      this.active = active;
    }
  }

  /** A row of {@code cron.job_run_details}, changed in place by the tests. */
  static final class Detail {
    final long runId;
    final long jobId;
    String status;
    @Nullable String message;
    @Nullable Long start;
    @Nullable Long end;

    Detail(
        long runId,
        long jobId,
        String status,
        @Nullable Long start,
        @Nullable Long end,
        @Nullable String message) {
      this.runId = runId;
      this.jobId = jobId;
      this.status = status;
      this.start = start;
      this.end = end;
      this.message = message;
    }
  }

  final List<Job> jobs = new CopyOnWriteArrayList<>();
  final List<Detail> details = new CopyOnWriteArrayList<>();
  final Map<String, @Nullable String> settings = new HashMap<>();
  final List<String> queries = new CopyOnWriteArrayList<>();
  private long runId;

  FakeCron() {
    settings.put("cron.timezone", "GMT");
    settings.put("cron.log_run", "on");
  }

  Job job(long jobId, @Nullable String jobName, String schedule) {
    return job(jobId, jobName, schedule, true);
  }

  Job job(long jobId, @Nullable String jobName, String schedule, boolean active) {
    Job j = new Job(jobId, jobName, schedule, active);
    jobs.add(j);
    return j;
  }

  Detail add(long jobId, String status, @Nullable Long start, @Nullable Long end) {
    return add(jobId, status, start, end, null);
  }

  Detail add(
      long jobId,
      String status,
      @Nullable Long start,
      @Nullable Long end,
      @Nullable String message) {
    Detail d = new Detail(++runId, jobId, status, start, end, message);
    details.add(d);
    return d;
  }

  private static Map<String, @Nullable Object> row(Detail d) {
    Map<String, @Nullable Object> r = new HashMap<>();
    r.put("runid", Long.toString(d.runId));
    r.put("jobid", Long.toString(d.jobId));
    r.put("status", d.status);
    r.put("return_message", d.message);
    r.put("start_time", d.start == null ? null : Instant.ofEpochMilli(d.start));
    r.put("end_time", d.end == null ? null : Instant.ofEpochMilli(d.end));
    return r;
  }

  /** An array literal, {@code {1,2,3}}, as the numbers it holds. */
  private static List<Long> array(Object literal) {
    String s = literal.toString();
    List<Long> out = new ArrayList<>();
    String inner = s.substring(1, s.length() - 1);
    if (!inner.isEmpty()) {
      for (String part : inner.split(",", -1)) {
        out.add(Long.parseLong(part));
      }
    }
    return out;
  }

  @Override
  public List<Map<String, @Nullable Object>> query(String sql, List<Object> params) {
    queries.add(sql);
    List<Map<String, @Nullable Object>> out = new ArrayList<>();
    if (sql.contains("pg_settings")) {
      String value = settings.get(String.valueOf(params.get(0)));
      if (value != null) {
        Map<String, @Nullable Object> r = new HashMap<>();
        r.put("setting", value);
        out.add(r);
      }
      return out;
    }
    if (sql.contains("FROM cron.job ORDER BY")) {
      for (Job j : jobs) {
        Map<String, @Nullable Object> r = new HashMap<>();
        r.put("jobid", Long.toString(j.jobId));
        r.put("jobname", j.jobName);
        r.put("schedule", j.schedule);
        r.put("database", "postgres");
        r.put("username", "postgres");
        r.put("active", j.active);
        out.add(r);
      }
      return out;
    }
    if (sql.contains("ORDER BY d.runid DESC")) {
      long jobId = (Long) params.get(0);
      details.stream()
          .filter(d -> d.jobId == jobId)
          .sorted(Comparator.comparingLong((Detail d) -> d.runId).reversed())
          .limit(20)
          .forEach(d -> out.add(row(d)));
      return out;
    }
    if (sql.contains("unnest")) {
      List<Long> ids = array(params.get(0));
      List<Long> afters = array(params.get(1));
      List<Long> open = array(params.get(2));
      Map<Long, Long> after = new HashMap<>();
      for (int i = 0; i < ids.size(); i++) {
        after.put(ids.get(i), afters.get(i));
      }
      details.stream()
          .filter(
              d ->
                  (after.containsKey(d.jobId) && d.runId > after.get(d.jobId))
                      || open.contains(d.runId))
          .sorted(Comparator.comparingLong(d -> d.runId))
          .limit(500)
          .forEach(d -> out.add(row(d)));
      return out;
    }
    throw new IllegalStateException("unexpected query " + sql);
  }
}
