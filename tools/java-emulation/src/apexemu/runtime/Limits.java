package apexemu.runtime;

public final class Limits {
  private static final int QUERY_LIMIT = 100;
  private static final int DML_LIMIT = 150;
  private static final ThreadLocal<State> STATE = ThreadLocal.withInitial(State::new);

  private Limits() {}

  public static void reset() {
    STATE.set(new State());
  }

  public static void configure(long cpuLimitMs, long heapLimitBytes) {
    State state = STATE.get();
    if (cpuLimitMs > 0) {
      state.cpuLimitMs = cpuLimitMs;
    }
    if (heapLimitBytes > 0) {
      state.heapLimitBytes = heapLimitBytes;
    }
  }

  public static void startTest() {
    State state = STATE.get();
    state.windowEnabled = true;
    state.windowClosed = false;
    state.windowStartNs = java.lang.System.nanoTime();
    state.windowStartSoqlCount = state.soqlCount;
    state.windowStartDmlCount = state.dmlCount;
    state.windowStartHeapBytes = state.heapBytes;
    state.windowStartUsedHeapBytes = usedHeapBytes();
  }

  public static void stopTest() {
    State state = STATE.get();
    if (!state.windowEnabled || state.windowClosed) {
      return;
    }
    state.windowClosed = true;
    state.windowCpuMs = elapsedMs(state.windowStartNs, java.lang.System.nanoTime());
    state.windowSoqlCount = Math.max(0, state.soqlCount - state.windowStartSoqlCount);
    state.windowDmlCount = Math.max(0, state.dmlCount - state.windowStartDmlCount);

    long trackedHeapDelta = Math.max(0L, state.heapBytes - state.windowStartHeapBytes);
    long actualHeapDelta = Math.max(0L, usedHeapBytes() - state.windowStartUsedHeapBytes);
    state.windowHeapBytes = Math.max(trackedHeapDelta, actualHeapDelta);
  }

  public static void addSoql(int count) {
    if (count <= 0) {
      return;
    }
    STATE.get().soqlCount += count;
  }

  public static void addDml(int count) {
    if (count <= 0) {
      return;
    }
    STATE.get().dmlCount += count;
  }

  public static void addHeapBytes(long bytes) {
    if (bytes <= 0) {
      return;
    }
    STATE.get().heapBytes += bytes;
  }

  public static int getQueries() {
    return snapshot().soqlCount();
  }

  public static int getDmlStatements() {
    return snapshot().dmlCount();
  }

  public static long getCpuTime() {
    return snapshot().cpuMs();
  }

  public static long getHeapSize() {
    return snapshot().heapBytes();
  }

  public static int getLimitQueries() {
    return QUERY_LIMIT;
  }

  public static int getLimitDmlStatements() {
    return DML_LIMIT;
  }

  public static int getLimitCpuTime() {
    State state = STATE.get();
    return (int) Math.max(0L, Math.min((long) Integer.MAX_VALUE, state.cpuLimitMs));
  }

  public static long getLimitHeapSize() {
    return STATE.get().heapLimitBytes;
  }

  public static Snapshot snapshot() {
    State state = STATE.get();
    if (state.windowEnabled) {
      if (state.windowClosed) {
        return new Snapshot(
            state.windowSoqlCount, state.windowDmlCount, state.windowHeapBytes, state.windowCpuMs, true);
      }

      long currentCpuMs = elapsedMs(state.windowStartNs, java.lang.System.nanoTime());
      int currentSoql = Math.max(0, state.soqlCount - state.windowStartSoqlCount);
      int currentDml = Math.max(0, state.dmlCount - state.windowStartDmlCount);
      long trackedHeapDelta = Math.max(0L, state.heapBytes - state.windowStartHeapBytes);
      long actualHeapDelta = Math.max(0L, usedHeapBytes() - state.windowStartUsedHeapBytes);
      long currentHeap = Math.max(trackedHeapDelta, actualHeapDelta);
      return new Snapshot(currentSoql, currentDml, currentHeap, currentCpuMs, true);
    }

    long cpuMs = elapsedMs(state.testStartNs, java.lang.System.nanoTime());
    long trackedHeap = Math.max(0L, state.heapBytes);
    long actualHeap = Math.max(0L, usedHeapBytes() - state.testStartUsedHeapBytes);
    long heap = Math.max(trackedHeap, actualHeap);
    return new Snapshot(state.soqlCount, state.dmlCount, heap, cpuMs, false);
  }

  public record Snapshot(int soqlCount, int dmlCount, long heapBytes, long cpuMs, boolean windowScoped) {}

  static void runWithFreshTransaction(Runnable runnable) {
    runWithFreshTransaction(
        () -> {
          runnable.run();
          return null;
        });
  }

  static <T> T runWithFreshTransaction(TransactionWork<T> work) {
    if (work == null) {
      throw new IllegalArgumentException("work cannot be null");
    }

    State previous = STATE.get();
    State isolated = new State();
    isolated.cpuLimitMs = previous.cpuLimitMs;
    isolated.heapLimitBytes = previous.heapLimitBytes;

    STATE.set(isolated);
    try {
      T result = work.run();
      Snapshot snapshot = snapshot();
      if (snapshot.cpuMs() > getLimitCpuTime()) {
        throw new AssertionError(
            "CPU limit exceeded: cpu_ms=" + snapshot.cpuMs() + " limit_ms=" + getLimitCpuTime());
      }
      if (snapshot.heapBytes() > getLimitHeapSize()) {
        throw new AssertionError(
            "Heap limit exceeded: heap_bytes=" + snapshot.heapBytes() + " limit_bytes=" + getLimitHeapSize());
      }
      return result;
    } finally {
      STATE.set(previous);
    }
  }

  private static long elapsedMs(long startNs, long endNs) {
    if (startNs <= 0L || endNs <= startNs) {
      return 0L;
    }
    return Math.max(1L, (endNs - startNs) / 1_000_000L);
  }

  private static long usedHeapBytes() {
    Runtime runtime = Runtime.getRuntime();
    return runtime.totalMemory() - runtime.freeMemory();
  }

  private static final class State {
    int soqlCount;
    int dmlCount;
    long heapBytes;
    long cpuLimitMs = 10_000L;
    long heapLimitBytes = 6_000_000L;
    long testStartNs = java.lang.System.nanoTime();
    long testStartUsedHeapBytes = usedHeapBytes();

    boolean windowEnabled;
    boolean windowClosed;
    long windowStartNs;
    int windowStartSoqlCount;
    int windowStartDmlCount;
    long windowStartHeapBytes;
    long windowStartUsedHeapBytes;

    long windowCpuMs;
    int windowSoqlCount;
    int windowDmlCount;
    long windowHeapBytes;
  }

  @FunctionalInterface
  interface TransactionWork<T> {
    T run();
  }
}
