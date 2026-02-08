package apexemu.runtime;

@FunctionalInterface
public interface Batchable {
  void execute(int scopeSize);

  default void finish() {}
}
