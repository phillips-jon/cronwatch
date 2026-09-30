package dev.cronwatch.spring;

import java.lang.reflect.Modifier;
import java.time.Duration;
import java.time.Instant;
import java.util.Optional;
import net.javacrumbs.shedlock.core.LockConfiguration;
import net.javacrumbs.shedlock.core.LockProvider;
import net.javacrumbs.shedlock.core.SimpleLock;
import org.aopalliance.intercept.MethodInterceptor;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.beans.BeansException;
import org.springframework.beans.factory.config.BeanPostProcessor;
import org.springframework.core.Ordered;

/**
 * ShedLock, when the app has it. Many apps run the same {@code @Scheduled} methods on every
 * instance and let ShedLock's {@code @SchedulerLock} choose one: on the instances that do not get
 * the lock, its proxy returns without running the method, inside Spring's observation, so each
 * would record a run that did nothing. This wraps the app's {@link LockProvider} beans so that, in
 * the method's thread, the run learns whether the first lock it asked for was taken; one whose lock
 * was not is given back, and only the instance that ran the method records it. It also runs the
 * starter's check under a lock of its own name, once per interval across the cluster.
 */
final class ShedLockSupport implements BeanPostProcessor, Ordered {
  /** The lock the starter's check takes. */
  static final String CHECK_LOCK = "cronwatch-check";

  /** Made by the starter's auto-configuration. */
  ShedLockSupport() {}

  @Override
  public int getOrder() {
    return Ordered.LOWEST_PRECEDENCE;
  }

  @Override
  public Object postProcessAfterInitialization(Object bean, String beanName) throws BeansException {
    if (!(bean instanceof LockProvider)) {
      return bean;
    }
    ProxyFactory factory = new ProxyFactory(bean);
    factory.setProxyTargetClass(!Modifier.isFinal(bean.getClass().getModifiers()));
    if (!factory.isProxyTargetClass()) {
      factory.setInterfaces(org.springframework.util.ClassUtils.getAllInterfaces(bean));
    }
    factory.addAdvice(
        (MethodInterceptor)
            invocation -> {
              Object answer = invocation.proceed();
              if (invocation.getMethod().getName().equals("lock")
                  && invocation.getArguments().length == 1
                  && invocation.getArguments()[0] instanceof LockConfiguration
                  && answer instanceof Optional<?> lock) {
                RunFrames.lockAnswered(lock.isPresent());
              }
              return answer;
            });
    return factory.getProxy(bean.getClass().getClassLoader());
  }

  /**
   * Runs {@code work} if this instance takes the check's lock, held at least most of {@code every}
   * so the other instances, whose intervals run a little apart, find it held, and at most ten times
   * it, in case this instance dies holding it. Says whether it ran.
   */
  static boolean underLock(LockProvider provider, Duration every, Runnable work) {
    Duration atLeast = every.multipliedBy(4).dividedBy(5);
    Duration atMost = every.multipliedBy(10);
    Optional<SimpleLock> lock =
        provider.lock(new LockConfiguration(Instant.now(), CHECK_LOCK, atMost, atLeast));
    if (lock.isEmpty()) {
      return false;
    }
    try {
      work.run();
    } finally {
      lock.get().unlock();
    }
    return true;
  }

  @Override
  public String toString() {
    return "ShedLockSupport";
  }
}
