package apexemu.runtime;

import java.util.ArrayList;
import java.util.List;

public final class Datacloud {
  private Datacloud() {}

  public static final class FindDuplicates {
    private FindDuplicates() {}

    public static List<FindDuplicatesResult> findDuplicates(List<ApexSObject> records) {
      List<FindDuplicatesResult> results = new ArrayList<>();
      if (records != null) {
        for (int i = 0; i < records.size(); i++) {
          results.add(new FindDuplicatesResult());
        }
      }
      return results;
    }
  }

  public static final class FindDuplicatesByIds {
    private FindDuplicatesByIds() {}

    public static List<FindDuplicatesResult> findDuplicatesByIds(List<String> recordIds) {
      return new ArrayList<>();
    }
  }

  public static class FindDuplicatesResult {
    private List<DuplicateResult> duplicateResults = new ArrayList<>();

    public List<DuplicateResult> getDuplicateResults() {
      return duplicateResults;
    }
  }

  public static class DuplicateResult {
    private List<MatchResult> matchResults = new ArrayList<>();
    private String duplicateRule;
    private boolean allowSave = false;

    public List<MatchResult> getMatchResults() {
      return matchResults;
    }

    public String getDuplicateRule() {
      return duplicateRule;
    }

    public boolean isAllowSave() {
      return allowSave;
    }
  }

  public static class MatchResult {
    private List<MatchRecord> matchRecords = new ArrayList<>();
    private String rule;

    public List<MatchRecord> getMatchRecords() {
      return matchRecords;
    }

    public String getRule() {
      return rule;
    }
  }

  public static class MatchRecord {
    private ApexSObject record;
    private Integer matchConfidence;

    public ApexSObject getRecord() {
      return record;
    }

    public Integer getMatchConfidence() {
      return matchConfidence;
    }
  }
}
