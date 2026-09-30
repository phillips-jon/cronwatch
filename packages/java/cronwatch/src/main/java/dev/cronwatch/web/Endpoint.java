package dev.cronwatch.web;

/**
 * What answers a {@link Request}: the dashboard ({@link Routes}) or a job's handler ({@link
 * Handler}). Every adapter ({@link WebServer}, the servlet filter and servlet, the Spring Boot
 * starter) is written over this one method.
 */
public interface Endpoint {
  /** Answers one request. Never throws but for an {@link Error}. */
  Response handle(Request request);
}
