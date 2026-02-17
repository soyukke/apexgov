package apexemu.runtime;

import java.io.IOException;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

final class TestData {
  private TestData() {}

  static List<ApexSObject> loadData(String sobjectType, String csvPath) {
    if (sobjectType == null || sobjectType.isBlank()) {
      throw new IllegalArgumentException("sobjectType cannot be blank");
    }
    if (csvPath == null || csvPath.isBlank()) {
      throw new IllegalArgumentException("csvPath cannot be blank");
    }

    List<String> lines = readLines(csvPath.trim());
    if (lines.isEmpty()) {
      return List.of();
    }

    List<String> header = parseCsvLine(lines.get(0));
    if (header.isEmpty()) {
      throw new IllegalArgumentException("CSV header cannot be empty: " + csvPath);
    }

    List<ApexSObject> rows = new ArrayList<>();
    for (int i = 1; i < lines.size(); i += 1) {
      String rawLine = lines.get(i);
      if (rawLine == null || rawLine.trim().isEmpty()) {
        continue;
      }
      List<String> values = parseCsvLine(rawLine);
      ApexSObject row = ApexSObject.of(sobjectType.trim());
      for (int col = 0; col < header.size(); col += 1) {
        String field = header.get(col) == null ? "" : header.get(col).trim();
        if (field.isEmpty()) {
          continue;
        }
        String rawValue = col < values.size() ? values.get(col) : null;
        row.set(field, parseCellValue(rawValue));
      }
      rows.add(row);
    }

    if (rows.isEmpty()) {
      return List.of();
    }
    Database.insert(rows);
    return rows;
  }

  private static List<String> readLines(String csvPath) {
    try {
      return Files.readAllLines(Path.of(csvPath), StandardCharsets.UTF_8);
    } catch (IOException error) {
      throw new IllegalArgumentException("failed to read CSV: " + csvPath, error);
    }
  }

  private static Object parseCellValue(String rawValue) {
    if (rawValue == null) {
      return null;
    }
    String value = rawValue.trim();
    if (value.isEmpty()) {
      return null;
    }
    if (value.equalsIgnoreCase("true") || value.equalsIgnoreCase("false")) {
      return Boolean.valueOf(value);
    }

    if (value.matches("[-+]?\\d+")) {
      try {
        long parsed = Long.parseLong(value);
        if (parsed >= Integer.MIN_VALUE && parsed <= Integer.MAX_VALUE) {
          return Integer.valueOf((int) parsed);
        }
        return Long.valueOf(parsed);
      } catch (NumberFormatException ignored) {
        // fallthrough
      }
    }

    if (value.matches("[-+]?\\d*\\.\\d+")) {
      try {
        return new BigDecimal(value);
      } catch (NumberFormatException ignored) {
        // fallthrough
      }
    }
    return value;
  }

  private static List<String> parseCsvLine(String line) {
    List<String> out = new ArrayList<>();
    if (line == null) {
      return out;
    }

    StringBuilder current = new StringBuilder();
    boolean inQuotes = false;
    for (int i = 0; i < line.length(); i += 1) {
      char ch = line.charAt(i);
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length() && line.charAt(i + 1) == '"') {
          current.append('"');
          i += 1;
        } else {
          inQuotes = !inQuotes;
        }
        continue;
      }
      if (ch == ',' && !inQuotes) {
        out.add(current.toString());
        current.setLength(0);
        continue;
      }
      current.append(ch);
    }
    out.add(current.toString());
    return out;
  }
}
