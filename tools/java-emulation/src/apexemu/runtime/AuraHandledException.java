package apexemu.runtime;

public class AuraHandledException extends System.AuraHandledException {
  private String message;

  public AuraHandledException(String message) {
    super(message);
    this.message = message;
  }

  public void setMessage(String message) {
    this.message = message;
  }

  @Override
  public String getMessage() {
    return message;
  }
}
