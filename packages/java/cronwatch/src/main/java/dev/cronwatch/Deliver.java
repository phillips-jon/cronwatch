package dev.cronwatch;

/** Where alerts are sent from. */
public enum Deliver {
  /** Each alert goes out from the process that produced it. The default. */
  NOW,
  /**
   * Nothing is sent from this process: each alert is queued in the store, and the next check in a
   * process that delivers now sends it (with triage). For a process that records runs but cannot
   * reach the network, such as a sandboxed backup job. Its channels and triage are not used.
   */
  AT_CHECK
}
