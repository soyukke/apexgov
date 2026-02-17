package apexemu.runtime;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public final class Messaging {
  private Messaging() {}

  public static final class inboundEmail {
    private inboundEmail() {}

    public static final class BinaryAttachment {
      public byte[] body;
      public String fileName;
    }
  }

  public static final class InboundEmail {
    public String fromAddress;
    public String fromName;
    public String subject;
    public String plainTextBody;
    public String htmlBody;
    public Map<String, String> headers;
    public List<String> toAddresses = new ArrayList<>();
    public List<inboundEmail.BinaryAttachment> binaryAttachments = new ArrayList<>();
  }
}
