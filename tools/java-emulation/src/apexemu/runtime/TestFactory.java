package apexemu.runtime;

import java.util.ArrayList;
import java.util.List;

public final class TestFactory {
  private TestFactory() {}

  public static List<ApexSObject> invalidateSObjectList(List<ApexSObject> rows) {
    if (rows == null) {
      return new ArrayList<>();
    }
    return new ArrayList<>(rows);
  }
}
