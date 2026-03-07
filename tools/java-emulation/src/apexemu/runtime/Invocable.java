package apexemu.runtime;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class Invocable {
  private Invocable() {}

  public static class Action {
    private String type;
    private String apiName;
    private List<Map<String, Object>> invocations = new ArrayList<>();

    public static Action createCustomAction(String type, String apiName) {
      Action action = new Action();
      action.type = type;
      action.apiName = apiName;
      return action;
    }

    public void setInvocations(List<Map<String, Object>> invocations) {
      if (invocations == null) {
        this.invocations = new ArrayList<>();
        return;
      }
      this.invocations = new ArrayList<>(invocations);
    }

    public List<Result> invoke() {
      List<Result> out = new ArrayList<>(invocations.size());
      for (Map<String, Object> invocation : invocations) {
        Result result = new Result();
        result.setAction(this);
        result.setSuccess(true);
        if (invocation != null) {
          result.getOutputParameters().putAll(invocation);
        }
        out.add(result);
      }
      return out;
    }

    public String getType() {
      return type;
    }

    public String getApiName() {
      return apiName;
    }

    public static class Result {
      private Action action;
      private List<Error> errors = new ArrayList<>();
      private Boolean success = true;
      private Map<String, Object> outputParameters = new LinkedHashMap<>();

      public Action getAction() {
        return action;
      }

      public void setAction(Action action) {
        this.action = action;
      }

      public List<Error> getErrors() {
        return errors == null ? new ArrayList<>() : errors;
      }

      public void setErrors(List<Error> errors) {
        this.errors = errors == null ? new ArrayList<>() : new ArrayList<>(errors);
      }

      public Boolean isSuccess() {
        return success == null ? Boolean.FALSE : success;
      }

      public void setSuccess(Boolean success) {
        this.success = success;
      }

      public Map<String, Object> getOutputParameters() {
        if (outputParameters == null) {
          outputParameters = new LinkedHashMap<>();
        }
        return outputParameters;
      }

      public void setOutputParameters(Map<String, Object> outputParameters) {
        this.outputParameters =
            outputParameters == null ? new LinkedHashMap<>() : new LinkedHashMap<>(outputParameters);
      }
    }

    public static class Error {
      private String code;
      private String message;

      public String getCode() {
        return code;
      }

      public void setCode(String code) {
        this.code = code;
      }

      public String getMessage() {
        return message;
      }

      public void setMessage(String message) {
        this.message = message;
      }
    }

    // Apex identifiers are case-insensitive. Keep a lowercase alias for transpiled references.
    public static final class error extends Error {}
  }
}
