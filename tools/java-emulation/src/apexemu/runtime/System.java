package apexemu.runtime;

public final class System {
  private System() {}

  public static String enqueueJob(Queueable job) {
    return Async.enqueueQueueable(job);
  }

  public static String schedule(String name, String cronExpr, Schedulable job) {
    if (name == null || name.isBlank()) {
      throw new IllegalArgumentException("schedule name cannot be blank");
    }
    if (cronExpr == null || cronExpr.isBlank()) {
      throw new IllegalArgumentException("cron expression cannot be blank");
    }
    return Async.enqueueSchedulable(job);
  }
}
