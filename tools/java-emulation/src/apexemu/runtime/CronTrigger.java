package apexemu.runtime;

public class CronTrigger {
  public String CronExpression;
  public Integer timesTriggered = 0;
  public String nextFireTime;

  @SuppressWarnings("unchecked")
  public <T> T getAs(String field) {
    return (T) ApexSwitch.getAs(this, field);
  }
}
