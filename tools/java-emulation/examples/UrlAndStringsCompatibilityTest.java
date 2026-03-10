package samples;

import apexemu.annotations.Test;
import apexemu.runtime.ApexStrings;
import apexemu.runtime.SystemAssert;
import apexemu.runtime.URL;

public final class UrlAndStringsCompatibilityTest {
  @Test
  public void supportsSalesforceBaseUrlAliasAndSubstringHelpers() {
    SystemAssert.assertEquals(
        "http://localhost",
        URL.getSalesforceBaseUrl().toExternalForm(),
        "Salesforce base URL alias mismatch");
    SystemAssert.assertEquals(
        "001xx0000000001",
        ApexStrings.substringAfterLast("https://example.invalid/001xx0000000001", "/"),
        "substringAfterLast mismatch");
    SystemAssert.assertEquals(
        "Mapping_Name",
        ApexStrings.substringBeforeLast("Mapping_Name_v2", "_"),
        "substringBeforeLast mismatch");
  }
}
