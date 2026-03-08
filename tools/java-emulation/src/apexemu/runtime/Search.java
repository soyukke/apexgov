package apexemu.runtime;

public final class Search {
  private Search() {}

  public static java.util.List<java.util.List<ApexSObject>> query(String sosl) {
    return new java.util.ArrayList<>(java.util.List.of(new java.util.ArrayList<>()));
  }

  public static class SearchBuilder {
    public SearchBuilder returning(String value) {
      return this;
    }

    public SearchBuilder find(String value) {
      return this;
    }

    public java.util.List<ApexSObject> execute() {
      return new java.util.ArrayList<>();
    }
  }
}
