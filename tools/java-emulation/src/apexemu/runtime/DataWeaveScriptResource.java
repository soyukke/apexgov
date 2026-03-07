package apexemu.runtime;

import java.util.Map;

public final class DataWeaveScriptResource {
  private DataWeaveScriptResource() {}

  private abstract static class ScriptBase implements DataWeave.Script {
    private final DataWeave.Script delegate;

    protected ScriptBase(String scriptName) {
      this.delegate = DataWeave.Script.createScript(scriptName);
    }

    @Override
    public DataWeave.Result execute(Map<String, Object> payload) {
      return delegate.execute(payload);
    }
  }

  public static final class helloWorld extends ScriptBase {
    public helloWorld() {
      super("helloWorld");
    }
  }

  public static final class error extends ScriptBase {
    public error() {
      super("error");
    }
  }

  public static final class excelOutputError extends ScriptBase {
    public excelOutputError() {
      super("excelOutputError");
    }
  }

  public static final class logFilter extends ScriptBase {
    public logFilter() {
      super("logFilter");
    }
  }

  public static final class csvToJsonBasic extends ScriptBase {
    public csvToJsonBasic() {
      super("csvToJsonBasic");
    }
  }

  public static final class csvToJsonWithFieldRenaming extends ScriptBase {
    public csvToJsonWithFieldRenaming() {
      super("csvToJsonWithFieldRenaming");
    }
  }

  public static final class csvSeparatorToJson extends ScriptBase {
    public csvSeparatorToJson() {
      super("csvSeparatorToJson");
    }
  }

  public static final class multipleInputs extends ScriptBase {
    public multipleInputs() {
      super("multipleInputs");
    }
  }

  public static final class csvToContacts extends ScriptBase {
    public csvToContacts() {
      super("csvToContacts");
    }
  }

  public static final class jsonToContacts extends ScriptBase {
    public jsonToContacts() {
      super("jsonToContacts");
    }
  }

  public static final class csvToApexObject extends ScriptBase {
    public csvToApexObject() {
      super("csvToApexObject");
    }
  }

  public static final class jsonDateFormat extends ScriptBase {
    public jsonDateFormat() {
      super("jsonDateFormat");
    }
  }

  public static final class pluralizeFunction extends ScriptBase {
    public pluralizeFunction() {
      super("pluralizeFunction");
    }
  }

  public static final class reservedApexKeywords extends ScriptBase {
    public reservedApexKeywords() {
      super("reservedApexKeywords");
    }
  }
}
