package apexemu.runtime;

public final class ApexDb {
  private static final long QUERY_HEAP_PER_ROW_BYTES = 48L;
  private static final long DML_HEAP_PER_ROW_BYTES = 24L;
  private static final long QUERY_CPU_NS_PER_ROW = 20_000L;
  private static final long DML_CPU_NS_PER_ROW = 30_000L;

  private ApexDb() {}

  public static void queryRows(int rows) {
    int normalized = Math.max(1, rows);
    Limits.addSoql(1);
    Limits.addHeapBytes(normalized * QUERY_HEAP_PER_ROW_BYTES);
    burnCpuNs(normalized * QUERY_CPU_NS_PER_ROW);
  }

  public static void dmlRows(int rows) {
    int normalized = Math.max(1, rows);
    Limits.addDml(1);
    Limits.addHeapBytes(normalized * DML_HEAP_PER_ROW_BYTES);
    burnCpuNs(normalized * DML_CPU_NS_PER_ROW);
  }

  public static void cpuBurnMs(long millis) {
    if (millis <= 0) {
      return;
    }
    burnCpuNs(millis * 1_000_000L);
  }

  private static void burnCpuNs(long targetNs) {
    if (targetNs <= 0) {
      return;
    }
    long start = java.lang.System.nanoTime();
    long value = 1;
    while (java.lang.System.nanoTime() - start < targetNs) {
      value = (value * 1_664_525L + 1_013_904_223L) & 0xFFFF_FFFFL;
    }
    if (value == Long.MIN_VALUE) {
      throw new IllegalStateException("unreachable");
    }
  }
}
