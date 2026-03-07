package apexemu.runtime;

/**
 * AggregateResult extends ApexSObject so that aggregate SOQL results
 * can be cast to AggregateResult in transpiled code.
 */
public class AggregateResult extends ApexSObject {
  public AggregateResult() {
    super("AggregateResult");
  }

  @Override
  public Object get(String field) {
    return super.get(field);
  }

  @Override
  @SuppressWarnings("unchecked")
  public <T> T getAs(String field) {
    return (T) get(field);
  }
}
