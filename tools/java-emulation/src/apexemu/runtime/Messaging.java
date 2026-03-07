package apexemu.runtime;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public final class Messaging {
  private Messaging() {}

  public static class Email {}

  public static final class SingleEmailMessage extends Email {
    private String targetObjectId;
    private String whatId;
    private String subject;
    private String plainTextBody;
    private String htmlBody;
    private String replyTo;
    private String senderDisplayName;
    private List<String> toAddresses = new ArrayList<>();

    public void setTargetObjectId(String value) {
      this.targetObjectId = value;
    }

    public String getTargetObjectId() {
      return targetObjectId;
    }

    public void setWhatId(String value) {
      this.whatId = value;
    }

    public String getWhatId() {
      return whatId;
    }

    public void setSubject(String value) {
      this.subject = value;
    }

    public String getSubject() {
      return subject;
    }

    public void setPlainTextBody(String value) {
      this.plainTextBody = value;
    }

    public String getPlainTextBody() {
      return plainTextBody;
    }

    public void setHtmlBody(String value) {
      this.htmlBody = value;
    }

    public String getHtmlBody() {
      return htmlBody;
    }

    public void setReplyTo(String value) {
      this.replyTo = value;
    }

    public String getReplyTo() {
      return replyTo;
    }

    public void setSenderDisplayName(String value) {
      this.senderDisplayName = value;
    }

    public String getSenderDisplayName() {
      return senderDisplayName;
    }

    public void setToAddresses(List<String> values) {
      this.toAddresses = values == null ? new ArrayList<>() : new ArrayList<>(values);
    }

    public List<String> getToAddresses() {
      return new ArrayList<>(toAddresses);
    }
  }

  public static final class InboundEmail {
    public static final class BinaryAttachment {
      public byte[] body;
      public String fileName;
      public String filename;

      @SuppressWarnings("unchecked")
      public <T> T getAs(String fieldName) {
        if (fieldName == null || fieldName.isBlank()) {
          return null;
        }
        String normalized = fieldName.trim().toLowerCase();
        Object value = switch (normalized) {
          case "body" -> body;
          case "filename" -> filename == null ? fileName : filename;
          default -> null;
        };
        return (T) value;
      }
    }

    public String fromAddress;
    public String fromName;
    public String subject;
    public String plainTextBody;
    public String htmlBody;
    public Map<String, String> headers;
    public List<String> toAddresses = new ArrayList<>();
    public List<BinaryAttachment> binaryAttachments = new ArrayList<>();

    @SuppressWarnings("unchecked")
    public <T> T getAs(String fieldName) {
      if (fieldName == null || fieldName.isBlank()) {
        return null;
      }
      String normalized = fieldName.trim().toLowerCase();
      Object value = switch (normalized) {
        case "fromaddress" -> fromAddress;
        case "fromname" -> fromName;
        case "subject" -> subject;
        case "plaintextbody" -> plainTextBody;
        case "htmlbody" -> htmlBody;
        case "headers" -> headers;
        case "toaddresses" -> toAddresses;
        case "binaryattachments" -> binaryAttachments;
        default -> null;
      };
      return (T) value;
    }
  }

  public static final class InboundEnvelope {
    public String fromAddress;
    public String toAddress;
  }

  public static final class InboundEmailResult {
    public Boolean success = true;
    public String message;
  }

  public interface InboundEmailHandler {
    InboundEmailResult handleInboundEmail(InboundEmail email, InboundEnvelope envelope);
  }

  public static void sendEmail(List<? extends Email> emails) {
    // best-effort emulation: no-op
  }
}
