package apexemu.runtime;

public interface Schedulable {
  default void execute(System.SchedulableContext context) {}

  default void execute() {}
}
