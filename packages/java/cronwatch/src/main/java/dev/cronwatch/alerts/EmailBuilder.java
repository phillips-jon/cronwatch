package dev.cronwatch.alerts;

import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

/**
 * What every email channel's options builder takes beyond a channel's: the sender, the recipients,
 * and a subject prefix. Resend, Postmark, SendGrid, Mailgun, and SES send the same mail: one
 * subject, a plain text body, and a small HTML body.
 *
 * @param <B> the builder itself
 */
public abstract class EmailBuilder<B extends EmailBuilder<B>> extends ChannelBuilder<B> {
  String from = "";
  List<String> to = new ArrayList<>();
  String subjectPrefix = "";

  EmailBuilder() {}

  /**
   * The sender, {@code alerts@example.com} or {@code CronWatch <alerts@example.com>}. The provider
   * must allow it.
   */
  public B from(String from) {
    this.from = Objects.requireNonNull(from, "from");
    return self();
  }

  /** One address or several, replacing any given before. Blank ones are left out. */
  public B to(String... to) {
    return to(List.of(to));
  }

  /** The addresses, replacing any given before. Blank ones are left out. */
  public B to(List<String> to) {
    this.to = new ArrayList<>(to);
    return self();
  }

  /** Put in front of the title in the subject, {@code [prod]} say. */
  public B subjectPrefix(String subjectPrefix) {
    this.subjectPrefix = Objects.requireNonNull(subjectPrefix, "subjectPrefix");
    return self();
  }

  /**
   * The settings every email channel shares, checked once, when the options are built: the to
   * addresses, blanks dropped, each trimmed.
   */
  Email.Settings email(String name) {
    if (from.isEmpty()) {
      throw Shared.invalid(name + " needs a from address");
    }
    List<String> kept = new ArrayList<>();
    for (String a : to) {
      if (a != null && !Shared.trimmed(a).isEmpty()) {
        kept.add(Shared.trimmed(a));
      }
    }
    if (kept.isEmpty()) {
      throw Shared.invalid(name + " needs at least one to address");
    }
    return new Email.Settings(from, List.copyOf(kept), subjectPrefix, link);
  }
}
