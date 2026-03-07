package apexemu.runtime;

import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.List;

public final class ConnectApi {
  private ConnectApi() {}

  public enum NamedCredentialType {
    SecuredEndpoint,
    Legacy,
    Unknown
  }

  public enum CredentialAuthenticationProtocol {
    Custom,
    OAuth,
    Unknown
  }

  public enum CredentialPrincipalType {
    NamedPrincipal,
    PerUser,
    Unknown
  }

  public static class Record {
    public Object get(String field) {
      return getAs(field);
    }

    @SuppressWarnings("unchecked")
    public <T> T getAs(String field) {
      if (field == null || field.isBlank()) {
        return null;
      }
      Field[] fields = getClass().getFields();
      for (Field candidate : fields) {
        if (candidate.getName().equalsIgnoreCase(field)) {
          try {
            return (T) candidate.get(this);
          } catch (IllegalAccessException ignored) {
            return null;
          }
        }
      }
      return null;
    }

    public void set(String field, Object value) {
      if (field == null || field.isBlank()) {
        return;
      }
      Field[] fields = getClass().getFields();
      for (Field candidate : fields) {
        if (candidate.getName().equalsIgnoreCase(field)) {
          try {
            candidate.set(this, value);
          } catch (IllegalAccessException ignored) {
            // best-effort emulation: ignore incompatible writes
          }
          return;
        }
      }
    }
  }

  public static final class ExternalCredentialInput extends Record {
    public String developerName;
    public String masterLabel;
    public Object authenticationProtocol;
    public List<ExternalCredentialPrincipalInput> principals = new ArrayList<>();
  }

  public static final class NamedCredentialInput extends Record {
    public String developerName;
    public String masterLabel;
    public Object type;
    public String calloutUrl;
    public List<?> externalCredentials = new ArrayList<>();
    public NamedCredentialCalloutOptionsInput calloutOptions;
  }

  public static class NamedCredentialCalloutOptionsInput extends Record {
    public Boolean allowMergeFieldsInBody;
    public Boolean allowMergeFieldsInHeader;
    public Boolean generateAuthorizationHeader;
  }

  public static final class ExternalCredentialPrincipalInput extends Record {
    public String principalName;
    public Object principalType;
    public Integer sequenceNumber;
  }

  public static final class ExternalCredentialPrincipal extends Record {
    public String id;
    public String principalName;
    public Object principalType;
    public Integer sequenceNumber;
  }

  public static final class ExternalCredential extends Record {
    public String id;
    public String developerName;
    public String masterLabel;
    public Object authenticationProtocol;
    public List<ExternalCredentialPrincipal> principals = new ArrayList<>();
  }

  public static final class NamedCredential extends Record {
    public String id;
    public String developerName;
    public String masterLabel;
    public Object type;
    public String calloutUrl;
    public List<ExternalCredential> externalCredentials = new ArrayList<>();
    public NamedCredentialCalloutOptionsInput calloutOptions;
  }

  public static final class NamedCredentialCalloutOptions extends NamedCredentialCalloutOptionsInput {}

  public static final class NamedCredentials {
    private NamedCredentials() {}

    public static ExternalCredential createExternalCredential(ExternalCredentialInput input) {
      ExternalCredential out = new ExternalCredential();
      if (input != null) {
        out.developerName = input.developerName;
        out.masterLabel = input.masterLabel;
        out.authenticationProtocol = input.authenticationProtocol;
        out.id = "ec-" + (out.developerName == null ? "generated" : out.developerName);
        if (input.principals != null) {
          for (ExternalCredentialPrincipalInput principalInput : input.principals) {
            if (principalInput == null) {
              continue;
            }
            ExternalCredentialPrincipal principal = new ExternalCredentialPrincipal();
            principal.principalName = principalInput.principalName;
            principal.principalType = principalInput.principalType;
            principal.sequenceNumber = principalInput.sequenceNumber;
            principal.id =
                "ecp-"
                    + (principal.principalName == null ? "generated" : principal.principalName);
            out.principals.add(principal);
          }
        }
      }
      return out;
    }

    public static NamedCredential createNamedCredential(NamedCredentialInput input) {
      NamedCredential out = new NamedCredential();
      if (input != null) {
        out.developerName = input.developerName;
        out.masterLabel = input.masterLabel;
        out.type = input.type;
        out.calloutUrl = input.calloutUrl;
        out.externalCredentials = new ArrayList<>();
        if (input.externalCredentials != null) {
          for (Object item : input.externalCredentials) {
            if (item instanceof ExternalCredential externalCredential) {
              out.externalCredentials.add(externalCredential);
              continue;
            }
            if (item instanceof ExternalCredentialInput externalCredentialInput) {
              out.externalCredentials.add(createExternalCredential(externalCredentialInput));
            }
          }
        }
        out.calloutOptions = input.calloutOptions;
      }
      out.id = "nc-" + (out.developerName == null ? "generated" : out.developerName);
      return out;
    }

    public static ExternalCredential getExternalCredential(String developerName) {
      ExternalCredential out = new ExternalCredential();
      out.developerName = developerName;
      out.id = "ec-" + (developerName == null ? "generated" : developerName);
      ExternalCredentialPrincipal principal = new ExternalCredentialPrincipal();
      principal.id = "ecp-default";
      principal.principalName = "default";
      out.principals = new ArrayList<>(List.of(principal));
      return out;
    }
  }

  public static final class ChatterUsers {
    private ChatterUsers() {}

    public static void getFollowings(String communityId, String userId) {
      if (!Test.isSeeAllDataEnabled()) {
        throw new UnsupportedOperationException(
            "ConnectApi.ChatterUsers.getFollowings requires @isTest(SeeAllData=true)");
      }
      // best-effort emulation: no-op
    }
  }
}
