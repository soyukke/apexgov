package apexemu.runtime;

public final class FormulaEval {
  private FormulaEval() {}

  public enum FormulaReturnType {
    Boolean
  }

  public enum FormulaGlobal {
    RECORD
  }

  public interface FormulaInstance {
    Object evaluate(Object context);
  }
}
