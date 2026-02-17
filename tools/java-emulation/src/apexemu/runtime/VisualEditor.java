package apexemu.runtime;

import java.util.ArrayList;
import java.util.List;

public final class VisualEditor {
  private VisualEditor() {}

  public static final class DataRow {
    private final String label;
    private final String value;

    public DataRow(String label, String value) {
      this.label = label;
      this.value = value;
    }

    public String getLabel() {
      return label;
    }

    public String getValue() {
      return value;
    }
  }

  public static final class DynamicPickListRows {
    private final List<DataRow> rows = new ArrayList<>();

    public void addRow(DataRow row) {
      if (row != null) {
        rows.add(row);
      }
    }

    public List<DataRow> getRows() {
      return rows;
    }
  }
}
