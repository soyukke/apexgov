package apexemu.runtime;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

public final class Metadata {
  private Metadata() {}

  private static class Record {
    public Object get(String field) {
      return ApexSwitch.getAs(this, field);
    }

    @SuppressWarnings("unchecked")
    public <T> T getAs(String field) {
      return (T) ApexSwitch.getAs(this, field);
    }

    public Map<String, Object> getPopulatedFieldsAsMap() {
      Map<String, Object> out = new LinkedHashMap<>();
      for (java.lang.reflect.Field field : this.getClass().getFields()) {
        try {
          Object value = field.get(this);
          if (value != null) {
            out.put(field.getName(), value);
          }
        } catch (IllegalAccessException ignored) {
        }
      }
      return out;
    }

    public Map<String, Object> toUntypedMap() {
      return getPopulatedFieldsAsMap();
    }
  }

  public interface DeployCallback {
    void handleResult(DeployResult deployResult, DeployCallbackContext context);
  }

  public static class DeployCallbackContext extends Record {}

  public enum DeployStatus {
    Succeeded,
    SUCCEEDED,
    FAILED,
    INPROGRESS,
    PENDING,
    CANCELING
  }

  public static class DeployMessage extends Record {
    public String fullName;
    public String problem;
  }

  public static class DeployDetails extends Record {
    public List<DeployMessage> componentFailures = new ArrayList<>();
  }

  public static class DeployResult extends Record {
    public String id;
    public DeployStatus status = DeployStatus.Succeeded;
    public DateTime completedDate;
    public DeployDetails details = new DeployDetails();
  }

  public static class CustomMetadataValue extends Record {
    public String field;
    public Object value;
  }

  public static class Origin extends Record {
    public String type;

    public Origin() {}

    public Origin(String type) {
      this.type = type;
    }
  }

  public static class CustomMetadata extends Record {
    public String fullName;
    public String label;
    public String description;
    public boolean protected_x;
    public List<CustomMetadataValue> values = new ArrayList<>();
    public Origin origin;
  }

  public static class DeployContainer extends Record {
    public List<CustomMetadata> metadata = new ArrayList<>();

    public void addMetadata(CustomMetadata value) {
      metadata.add(value);
    }
  }

  public static final class Operations {
    private Operations() {}

    public static String enqueueDeployment(DeployContainer container, DeployCallback callback) {
      return UUID.randomUUID().toString();
    }
  }
}
