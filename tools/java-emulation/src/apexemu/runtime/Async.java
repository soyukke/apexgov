package apexemu.runtime;

import apexemu.annotations.Future;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.ArrayDeque;
import java.util.Deque;

public final class Async {
  private static final int MAX_FLUSH_JOBS = 1000;
  private static final ThreadLocal<State> STATE = ThreadLocal.withInitial(State::new);

  private Async() {}

  public static void reset() {
    STATE.set(new State());
  }

  public static void startTestWindow() {
    State state = STATE.get();
    state.windowStarted = true;
    state.pending.clear();
    state.enqueuedTotal = 0;
    state.enqueuedFuture = 0;
    state.enqueuedQueueable = 0;
    state.enqueuedBatch = 0;
    state.enqueuedSchedulable = 0;
    state.flushedTotal = 0;
  }

  public static String enqueueFuture(Runnable task) {
    if (task == null) {
      throw new IllegalArgumentException("future task cannot be null");
    }
    State state = STATE.get();
    String id = nextJobId(state, "future");
    enqueue(state, new Job(id, Kind.FUTURE, task, null, null, 0));
    state.enqueuedFuture += 1;
    return id;
  }

  public static String enqueueFutureMethod(Class<?> owner, String methodName) {
    if (owner == null) {
      throw new IllegalArgumentException("owner cannot be null");
    }
    if (methodName == null || methodName.isBlank()) {
      throw new IllegalArgumentException("methodName cannot be blank");
    }

    final Method method;
    try {
      method = owner.getDeclaredMethod(methodName);
    } catch (NoSuchMethodException error) {
      throw new IllegalArgumentException(
          "future method not found: " + owner.getName() + "#" + methodName + "()", error);
    }

    if (!Modifier.isStatic(method.getModifiers())) {
      throw new IllegalArgumentException("future method must be static: " + owner.getName() + "#" + methodName);
    }
    if (method.getParameterCount() != 0) {
      throw new IllegalArgumentException(
          "future method must have zero arguments: " + owner.getName() + "#" + methodName);
    }
    if (!method.isAnnotationPresent(Future.class)) {
      throw new IllegalArgumentException(
          "future method must be annotated with @Future: " + owner.getName() + "#" + methodName);
    }

    method.setAccessible(true);
    return enqueueFuture(
        () -> {
          try {
            method.invoke(null);
          } catch (IllegalAccessException error) {
            throw new IllegalStateException("failed to execute future method: " + owner.getName() + "#" + methodName, error);
          } catch (InvocationTargetException error) {
            Throwable cause = error.getCause();
            if (cause instanceof RuntimeException runtimeError) {
              throw runtimeError;
            }
            if (cause instanceof Error severeError) {
              throw severeError;
            }
            throw new IllegalStateException(
                "future method threw checked exception: " + owner.getName() + "#" + methodName, cause);
          }
        });
  }

  public static String enqueueQueueable(Queueable job) {
    if (job == null) {
      throw new IllegalArgumentException("queueable job cannot be null");
    }
    State state = STATE.get();
    String id = nextJobId(state, "queueable");
    enqueue(state, new Job(id, Kind.QUEUEABLE, null, job, null, 0));
    state.enqueuedQueueable += 1;
    return id;
  }

  public static String enqueueBatch(Batchable job, int scopeSize) {
    if (job == null) {
      throw new IllegalArgumentException("batch job cannot be null");
    }
    int normalizedScope = Math.max(1, scopeSize);
    State state = STATE.get();
    String id = nextJobId(state, "batch");
    enqueue(state, new Job(id, Kind.BATCH, null, null, job, normalizedScope));
    state.enqueuedBatch += 1;
    return id;
  }

  public static String enqueueSchedulable(Schedulable job) {
    if (job == null) {
      throw new IllegalArgumentException("schedulable job cannot be null");
    }
    State state = STATE.get();
    String id = nextJobId(state, "sched");
    enqueue(state, new Job(id, Kind.SCHEDULABLE, null, null, null, 0, job));
    state.enqueuedSchedulable += 1;
    return id;
  }

  public static void flush() {
    State state = STATE.get();
    int ran = 0;
    while (!state.pending.isEmpty()) {
      ran += 1;
      if (ran > MAX_FLUSH_JOBS) {
        throw new IllegalStateException("async flush exceeded max jobs: " + MAX_FLUSH_JOBS);
      }

      Job job = state.pending.removeFirst();
      switch (job.kind) {
        case FUTURE -> job.futureTask.run();
        case QUEUEABLE -> job.queueableJob.execute();
        case BATCH -> {
          job.batchJob.execute(job.batchScopeSize);
          job.batchJob.finish();
        }
        case SCHEDULABLE -> job.schedulableJob.execute();
      }
      state.flushedTotal += 1;
    }
  }

  public static Snapshot snapshot() {
    State state = STATE.get();
    return new Snapshot(
        state.pending.size(),
        state.enqueuedTotal,
        state.flushedTotal,
        state.enqueuedFuture,
        state.enqueuedQueueable,
        state.enqueuedBatch,
        state.enqueuedSchedulable,
        state.windowStarted);
  }

  private static void enqueue(State state, Job job) {
    state.pending.addLast(job);
    state.enqueuedTotal += 1;
  }

  private static String nextJobId(State state, String prefix) {
    state.jobSequence += 1L;
    return prefix + "-" + state.jobSequence;
  }

  public record Snapshot(
      int pendingJobs,
      int enqueuedJobs,
      int flushedJobs,
      int futureJobs,
      int queueableJobs,
      int batchJobs,
      int schedulableJobs,
      boolean testWindowStarted) {}

  private enum Kind {
    FUTURE,
    QUEUEABLE,
    BATCH,
    SCHEDULABLE
  }

  private static final class Job {
    final String id;
    final Kind kind;
    final Runnable futureTask;
    final Queueable queueableJob;
    final Batchable batchJob;
    final int batchScopeSize;
    final Schedulable schedulableJob;

    Job(
        String id,
        Kind kind,
        Runnable futureTask,
        Queueable queueableJob,
        Batchable batchJob,
        int batchScopeSize) {
      this(id, kind, futureTask, queueableJob, batchJob, batchScopeSize, null);
    }

    Job(
        String id,
        Kind kind,
        Runnable futureTask,
        Queueable queueableJob,
        Batchable batchJob,
        int batchScopeSize,
        Schedulable schedulableJob) {
      this.id = id;
      this.kind = kind;
      this.futureTask = futureTask;
      this.queueableJob = queueableJob;
      this.batchJob = batchJob;
      this.batchScopeSize = batchScopeSize;
      this.schedulableJob = schedulableJob;
    }
  }

  private static final class State {
    final Deque<Job> pending = new ArrayDeque<>();
    long jobSequence;
    int enqueuedTotal;
    int flushedTotal;
    int enqueuedFuture;
    int enqueuedQueueable;
    int enqueuedBatch;
    int enqueuedSchedulable;
    boolean windowStarted;
  }
}
