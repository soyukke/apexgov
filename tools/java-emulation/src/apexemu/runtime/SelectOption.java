package apexemu.runtime;

public final class SelectOption {
  private final String value;
  private final String label;
  private final Boolean disabled;

  public SelectOption(String value, String label) {
    this(value, label, false);
  }

  public SelectOption(String value, String label, Boolean disabled) {
    this.value = value;
    this.label = label;
    this.disabled = disabled == null ? false : disabled;
  }

  public String getValue() {
    return value;
  }

  public String getLabel() {
    return label;
  }

  public Boolean getDisabled() {
    return disabled;
  }
}
