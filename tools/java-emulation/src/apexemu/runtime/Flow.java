package apexemu.runtime;

import java.util.LinkedHashMap;
import java.util.Map;

public final class Flow {
  private Flow() {}

  public static class Interview {
    private final Map<String, Object> variables = new LinkedHashMap<>();

    public Interview() {}

    public Interview(Map<String, Object> inputs) {
      if (inputs != null) {
        variables.putAll(inputs);
      }
    }

    public static Interview createInterview(String flowApiName, Map<String, Object> inputs) {
      return new Interview(inputs);
    }

    public void start() {}

    public Object getVariableValue(String name) {
      if (name == null) {
        return null;
      }
      return variables.get(name);
    }

    public void setVariableValue(String name, Object value) {
      if (name == null) {
        return;
      }
      variables.put(name, value);
    }
  }
}
