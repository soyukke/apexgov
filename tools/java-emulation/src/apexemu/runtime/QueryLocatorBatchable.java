package apexemu.runtime;

import java.util.List;

public interface QueryLocatorBatchable {
  Database.QueryLocator start();

  void execute(List<ApexSObject> scope);

  default void finish() {}
}
