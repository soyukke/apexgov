package apexemu.runtime;

import java.util.Map;

public interface Callable extends System.Callable {
  @Override
  Object call(String action, Map<String, Object> args);
}
