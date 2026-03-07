package apexemu.runtime;

import java.util.List;

public interface Batchable<T> {
  default Object start(Database.BatchableContext context) {
    return null;
  }

  default void execute(Database.BatchableContext context, List<T> scope) {}

  default void finish(Database.BatchableContext context) {}

  default void execute(int scopeSize) {}

  default void finish() {}
}
