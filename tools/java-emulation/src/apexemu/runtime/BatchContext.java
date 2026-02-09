package apexemu.runtime;

public final class BatchContext {
  private static final ThreadLocal<State> STATE = ThreadLocal.withInitial(State::new);

  private BatchContext() {}

  public static String getJobId() {
    return STATE.get().jobId;
  }

  public static int getScopeIndex() {
    return STATE.get().scopeIndex;
  }

  public static int getTotalScopes() {
    return STATE.get().totalScopes;
  }

  public static Phase getPhase() {
    return STATE.get().phase;
  }

  public static boolean isStart() {
    return getPhase() == Phase.START;
  }

  public static boolean isExecute() {
    return getPhase() == Phase.EXECUTE;
  }

  public static boolean isFinish() {
    return getPhase() == Phase.FINISH;
  }

  public static boolean isExecuting() {
    return STATE.get().jobId != null;
  }

  static void enter(String jobId, int scopeIndex, int totalScopes, Phase phase) {
    State state = STATE.get();
    state.jobId = normalizeJobId(jobId);
    state.scopeIndex = Math.max(0, scopeIndex);
    state.totalScopes = Math.max(0, totalScopes);
    state.phase = phase == null ? Phase.NONE : phase;
  }

  static void clear() {
    STATE.set(new State());
  }

  private static String normalizeJobId(String jobId) {
    if (jobId == null || jobId.isBlank()) {
      return null;
    }
    return jobId.trim();
  }

  private static final class State {
    String jobId;
    int scopeIndex;
    int totalScopes;
    Phase phase = Phase.NONE;
  }

  public enum Phase {
    NONE,
    START,
    EXECUTE,
    FINISH
  }
}
