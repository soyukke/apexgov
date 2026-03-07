package apexemu.runtime;

import apexemu.annotations.Future;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.ArrayList;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.List;

public final class Async {
  private static final int MAX_FLUSH_JOBS = 1000;
  private static final ThreadLocal<State> STATE = ThreadLocal.withInitial(State::new);

  private Async() {}

  public static void reset() {
    STATE.set(new State());
    BatchContext.clear();
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

  public static String enqueueBatch(QueryLocatorBatchable job, int scopeSize) {
    if (job == null) {
      throw new IllegalArgumentException("batch job cannot be null");
    }
    int normalizedScope = Math.max(1, scopeSize);
    State state = STATE.get();
    String id = nextJobId(state, "batch");
    enqueue(state, new Job(id, Kind.BATCH_QUERY_LOCATOR, job, normalizedScope));
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
        case QUEUEABLE -> runQueueable(job.queueableJob, job.id);
        case BATCH -> executeBatch(job.id, job.batchJob, job.batchScopeSize);
        case BATCH_QUERY_LOCATOR ->
            executeQueryLocatorBatch(job.id, job.queryLocatorBatchJob, job.batchScopeSize);
        case SCHEDULABLE -> runSchedulable(job.schedulableJob, job.id);
      }
      state.flushedTotal += 1;
    }
  }

  private static void executeQueryLocatorBatch(
      String jobId, QueryLocatorBatchable batchJob, int scopeSize) {
    if (batchJob == null) {
      throw new IllegalArgumentException("query locator batch job cannot be null");
    }

    Database.QueryLocator locator =
        runBatchPhase(jobId, 0, 0, scopeSize, 0, BatchContext.Phase.START, batchJob::start);
    if (locator == null) {
      throw new IllegalArgumentException("batch start cannot return null query locator");
    }

    List<ApexSObject> allRows = locator.getRecords();
    int totalScopes = countTotalScopes(allRows, scopeSize);
    if (allRows != null && !allRows.isEmpty()) {
      int scopeIndex = 0;
      for (int offset = 0; offset < allRows.size(); offset += scopeSize) {
        scopeIndex += 1;
        int end = Math.min(offset + scopeSize, allRows.size());
        List<ApexSObject> scope = new ArrayList<>(end - offset);
        for (int i = offset; i < end; i += 1) {
          ApexSObject row = allRows.get(i);
          scope.add(row == null ? null : row.copy());
        }
        List<ApexSObject> immutableScope = List.copyOf(scope);
        runBatchPhase(
            jobId,
            scopeIndex,
            totalScopes,
            scopeSize,
            immutableScope.size(),
            BatchContext.Phase.EXECUTE,
            () -> batchJob.execute(immutableScope));
      }
    }

    runBatchPhase(jobId, 0, totalScopes, scopeSize, 0, BatchContext.Phase.FINISH, batchJob::finish);
  }

  private static void executeBatch(String jobId, Batchable batchJob, int scopeSize) {
    if (batchJob == null) {
      throw new IllegalArgumentException("batch job cannot be null");
    }

    if (overridesBatchableMethod(batchJob, "execute", Database.BatchableContext.class, List.class)) {
      Database.BatchableContext context = new Database.BatchableContext(jobId);
      Object startResult =
          runBatchPhase(
              jobId,
              0,
              0,
              scopeSize,
              0,
              BatchContext.Phase.START,
              () -> batchJob.start(context));
      List<ApexSObject> allRows = coerceBatchRows(startResult);
      int totalScopes = countTotalScopes(allRows, scopeSize);
      if (allRows != null && !allRows.isEmpty()) {
        int scopeIndex = 0;
        for (int offset = 0; offset < allRows.size(); offset += scopeSize) {
          scopeIndex += 1;
          int end = Math.min(offset + scopeSize, allRows.size());
          List<ApexSObject> scope = new ArrayList<>(end - offset);
          for (int i = offset; i < end; i += 1) {
            ApexSObject row = allRows.get(i);
            scope.add(row == null ? null : row.copy());
          }
          List<ApexSObject> immutableScope = List.copyOf(scope);
          runBatchPhase(
              jobId,
              scopeIndex,
              totalScopes,
              scopeSize,
              immutableScope.size(),
              BatchContext.Phase.EXECUTE,
              () -> batchJob.execute(context, immutableScope));
        }
      }
      runBatchPhase(
          jobId, 0, totalScopes, scopeSize, 0, BatchContext.Phase.FINISH, () -> batchJob.finish(context));
      return;
    }

    runBatchPhase(
        jobId,
        1,
        1,
        scopeSize,
        scopeSize,
        BatchContext.Phase.EXECUTE,
        () -> batchJob.execute(scopeSize));
    runBatchPhase(jobId, 0, 1, scopeSize, 0, BatchContext.Phase.FINISH, (Runnable) batchJob::finish);
  }

  private static boolean overridesBatchableMethod(
      Batchable batchJob, String methodName, Class<?>... parameterTypes) {
    if (batchJob == null || methodName == null || methodName.isBlank()) {
      return false;
    }
    try {
      Method method = batchJob.getClass().getMethod(methodName, parameterTypes);
      return method.getDeclaringClass() != Batchable.class;
    } catch (NoSuchMethodException ignored) {
      return false;
    }
  }

  private static List<ApexSObject> coerceBatchRows(Object startResult) {
    if (startResult == null) {
      return List.of();
    }
    if (startResult instanceof Database.QueryLocator locator) {
      List<ApexSObject> rows = locator.getRecords();
      return rows == null ? List.of() : rows;
    }
    if (startResult instanceof Iterable<?> iterable) {
      List<ApexSObject> rows = new ArrayList<>();
      for (Object item : iterable) {
        if (item instanceof ApexSObject row) {
          rows.add(row);
        }
      }
      return rows;
    }
    return List.of();
  }

  private static int countTotalScopes(List<ApexSObject> rows, int scopeSize) {
    if (rows == null || rows.isEmpty() || scopeSize <= 0) {
      return 0;
    }
    return (rows.size() + scopeSize - 1) / scopeSize;
  }

  private static void runQueueable(Queueable queueableJob, String jobId) {
    if (queueableJob == null) {
      throw new IllegalArgumentException("queueable job cannot be null");
    }
    System.QueueableContext context = new System.QueueableContext(jobId);
    boolean invoked =
        invokeQueueable(
            queueableJob,
            "execute",
            new Class<?>[] {System.QueueableContext.class},
            new Object[] {context});
    if (!invoked) {
      invoked = invokeQueueable(queueableJob, "execute", new Class<?>[0], new Object[0]);
    }
    if (!invoked) {
      throw new IllegalStateException("queueable class has no execute method: " + queueableJob.getClass().getName());
    }
  }

  private static void runSchedulable(Schedulable schedulableJob, String jobId) {
    if (schedulableJob == null) {
      throw new IllegalArgumentException("schedulable job cannot be null");
    }
    boolean invoked =
        invokeSchedulable(
            schedulableJob,
            "execute",
            new Class<?>[] {System.SchedulableContext.class},
            new Object[] {new System.SchedulableContext(jobId)});
    if (!invoked) {
      invoked = invokeSchedulable(schedulableJob, "execute", new Class<?>[0], new Object[0]);
    }
    if (!invoked) {
      throw new IllegalStateException(
          "schedulable class has no execute method: " + schedulableJob.getClass().getName());
    }
  }

  private static boolean invokeQueueable(
      Queueable target, String methodName, Class<?>[] paramTypes, Object[] args) {
    final Method method;
    try {
      method = target.getClass().getDeclaredMethod(methodName, paramTypes);
    } catch (NoSuchMethodException ignored) {
      return false;
    }

    method.setAccessible(true);
    try {
      if (Modifier.isStatic(method.getModifiers())) {
        method.invoke(null, args);
      } else {
        method.invoke(target, args);
      }
      return true;
    } catch (IllegalAccessException error) {
      throw new IllegalStateException(
          "failed to execute queueable method: " + target.getClass().getName() + "#" + methodName,
          error);
    } catch (InvocationTargetException error) {
      Throwable cause = error.getCause();
      if (cause instanceof RuntimeException runtimeError) {
        throw runtimeError;
      }
      if (cause instanceof Error severeError) {
        throw severeError;
      }
      throw new IllegalStateException(
          "queueable method threw checked exception: "
              + target.getClass().getName()
              + "#"
              + methodName,
          cause);
    }
  }

  private static boolean invokeSchedulable(
      Schedulable target, String methodName, Class<?>[] paramTypes, Object[] args) {
    final Method method;
    try {
      method = target.getClass().getDeclaredMethod(methodName, paramTypes);
    } catch (NoSuchMethodException ignored) {
      return false;
    }

    method.setAccessible(true);
    try {
      if (Modifier.isStatic(method.getModifiers())) {
        method.invoke(null, args);
      } else {
        method.invoke(target, args);
      }
      return true;
    } catch (IllegalAccessException error) {
      throw new IllegalStateException(
          "failed to execute schedulable method: " + target.getClass().getName() + "#" + methodName,
          error);
    } catch (InvocationTargetException error) {
      Throwable cause = error.getCause();
      if (cause instanceof RuntimeException runtimeError) {
        throw runtimeError;
      }
      if (cause instanceof Error severeError) {
        throw severeError;
      }
      throw new IllegalStateException(
          "schedulable method threw checked exception: "
              + target.getClass().getName()
              + "#"
              + methodName,
          cause);
    }
  }

  private static <T> T runBatchPhase(
      String jobId,
      int scopeIndex,
      int totalScopes,
      int scopeSize,
      int scopeRecordCount,
      BatchContext.Phase phase,
      Limits.TransactionWork<T> work) {
    BatchContext.enter(jobId, scopeIndex, totalScopes, scopeSize, scopeRecordCount, phase);
    try {
      return Limits.runWithFreshTransaction(work);
    } finally {
      BatchContext.clear();
    }
  }

  private static void runBatchPhase(
      String jobId,
      int scopeIndex,
      int totalScopes,
      int scopeSize,
      int scopeRecordCount,
      BatchContext.Phase phase,
      Runnable runnable) {
    runBatchPhase(
        jobId,
        scopeIndex,
        totalScopes,
        scopeSize,
        scopeRecordCount,
        phase,
        () -> {
          runnable.run();
          return null;
        });
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
    BATCH_QUERY_LOCATOR,
    SCHEDULABLE
  }

  private static final class Job {
    final String id;
    final Kind kind;
    final Runnable futureTask;
    final Queueable queueableJob;
    final Batchable batchJob;
    final QueryLocatorBatchable queryLocatorBatchJob;
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

    Job(String id, Kind kind, QueryLocatorBatchable queryLocatorBatchJob, int batchScopeSize) {
      this(id, kind, null, null, null, queryLocatorBatchJob, batchScopeSize, null);
    }

    Job(
        String id,
        Kind kind,
        Runnable futureTask,
        Queueable queueableJob,
        Batchable batchJob,
        int batchScopeSize,
        Schedulable schedulableJob) {
      this(id, kind, futureTask, queueableJob, batchJob, null, batchScopeSize, schedulableJob);
    }

    Job(
        String id,
        Kind kind,
        Runnable futureTask,
        Queueable queueableJob,
        Batchable batchJob,
        QueryLocatorBatchable queryLocatorBatchJob,
        int batchScopeSize,
        Schedulable schedulableJob) {
      this.id = id;
      this.kind = kind;
      this.futureTask = futureTask;
      this.queueableJob = queueableJob;
      this.batchJob = batchJob;
      this.queryLocatorBatchJob = queryLocatorBatchJob;
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
