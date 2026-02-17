package apexemu.runtime;

public final class ApexPages {
  private static final ThreadLocal<PageReference> CURRENT_PAGE =
      ThreadLocal.withInitial(() -> new PageReference(""));

  private ApexPages() {}

  public static PageReference currentPage() {
    return CURRENT_PAGE.get();
  }

  static void setCurrentPage(PageReference pageReference) {
    CURRENT_PAGE.set(pageReference == null ? new PageReference("") : pageReference);
  }
}
