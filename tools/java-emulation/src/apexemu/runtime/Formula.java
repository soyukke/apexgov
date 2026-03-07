package apexemu.runtime;

import java.util.Locale;
import java.util.Objects;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public final class Formula {
  private Formula() {}

  public static Builder builder() {
    return new Builder();
  }

  public static final class Builder {
    private FormulaEval.FormulaReturnType returnType;
    private FormulaEval.FormulaGlobal[] globals = new FormulaEval.FormulaGlobal[0];
    private System.Type type;
    private String formula;

    public Builder withReturnType(FormulaEval.FormulaReturnType returnType) {
      this.returnType = returnType;
      return this;
    }

    public Builder withGlobalVariables(FormulaEval.FormulaGlobal[] globals) {
      this.globals = globals == null ? new FormulaEval.FormulaGlobal[0] : globals.clone();
      return this;
    }

    public Builder withType(System.Type type) {
      this.type = type;
      return this;
    }

    public Builder withFormula(String formula) {
      this.formula = formula;
      return this;
    }

    public FormulaEval.FormulaInstance build() {
      if (returnType != FormulaEval.FormulaReturnType.Boolean) {
        throw new System.FormulaValidationException("only Boolean return type is supported");
      }
      if (formula == null || formula.isBlank()) {
        throw new System.FormulaValidationException("formula must not be blank");
      }
      String normalized = formula.trim();
      if (normalized.contains("!!!")) {
        throw new System.FormulaValidationException("invalid formula syntax");
      }
      return new BasicFormulaInstance(normalized, type, globals);
    }
  }

  private static final class BasicFormulaInstance implements FormulaEval.FormulaInstance {
    private static final Pattern EQUALITY =
        Pattern.compile("^record\\.([A-Za-z0-9_]+)\\s*(==|=)\\s*\"([^\"]*)\"$", Pattern.CASE_INSENSITIVE);
    private static final Pattern EQUALITY_SINGLE =
        Pattern.compile("^record\\.([A-Za-z0-9_]+)\\s*(==|=)\\s*'([^']*)'$", Pattern.CASE_INSENSITIVE);
    private static final Pattern CONTAINS =
        Pattern.compile(
            "^CONTAINS\\s*\\(\\s*record\\.([A-Za-z0-9_]+)\\s*,\\s*\"([^\"]*)\"\\s*\\)$",
            Pattern.CASE_INSENSITIVE);
    private static final Pattern CONTAINS_SINGLE =
        Pattern.compile(
            "^CONTAINS\\s*\\(\\s*record\\.([A-Za-z0-9_]+)\\s*,\\s*'([^']*)'\\s*\\)$",
            Pattern.CASE_INSENSITIVE);

    private final String formula;
    @SuppressWarnings("unused")
    private final System.Type type;
    @SuppressWarnings("unused")
    private final FormulaEval.FormulaGlobal[] globals;

    BasicFormulaInstance(String formula, System.Type type, FormulaEval.FormulaGlobal[] globals) {
      this.formula = formula;
      this.type = type;
      this.globals = globals == null ? new FormulaEval.FormulaGlobal[0] : globals.clone();
    }

    @Override
    public Object evaluate(Object context) {
      ApexSObject record = resolveRecord(context);
      if (record == null) {
        return null;
      }

      Matcher eq = EQUALITY.matcher(formula);
      if (eq.matches()) {
        String field = eq.group(1);
        String expected = eq.group(3);
        Object actual = record.get(field);
        return Objects.equals(actual == null ? null : String.valueOf(actual), expected);
      }

      Matcher eqSingle = EQUALITY_SINGLE.matcher(formula);
      if (eqSingle.matches()) {
        String field = eqSingle.group(1);
        String expected = eqSingle.group(3);
        Object actual = record.get(field);
        return Objects.equals(actual == null ? null : String.valueOf(actual), expected);
      }

      Matcher contains = CONTAINS.matcher(formula);
      if (contains.matches()) {
        String field = contains.group(1);
        String needle = contains.group(2);
        Object actual = record.get(field);
        if (actual == null) {
          return null;
        }
        return String.valueOf(actual).toLowerCase(Locale.ROOT).contains(needle.toLowerCase(Locale.ROOT));
      }

      Matcher containsSingle = CONTAINS_SINGLE.matcher(formula);
      if (containsSingle.matches()) {
        String field = containsSingle.group(1);
        String needle = containsSingle.group(2);
        Object actual = record.get(field);
        if (actual == null) {
          return null;
        }
        return String.valueOf(actual).toLowerCase(Locale.ROOT).contains(needle.toLowerCase(Locale.ROOT));
      }

      throw new System.FormulaValidationException("unsupported formula expression: " + formula);
    }

    private ApexSObject resolveRecord(Object context) {
      if (context == null) {
        return null;
      }
      if (context instanceof ApexSObject row) {
        return row;
      }
      Object record = ApexSwitch.getAs(context, "record");
      if (record instanceof ApexSObject row) {
        return row;
      }
      Object newRecord = ApexSwitch.getAs(context, "newSobject");
      if (newRecord instanceof ApexSObject row) {
        return row;
      }
      return null;
    }
  }
}
