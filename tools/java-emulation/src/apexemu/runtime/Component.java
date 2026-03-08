package apexemu.runtime;

import java.util.ArrayList;
import java.util.List;

public final class Component {
  private Component() {}

  public static class Expressions {
    public String action;
    public String value;
    public String sObj;
  }

  public static class Base {
    public final List<Object> childComponents = new ArrayList<>();
    public final Expressions expressions = new Expressions();
    public String id;
    public String value;
    public String styleClass;
    public String layout;
    public String style;
    public Boolean escape;
    public Boolean immediate;
    public Integer size;
    public Boolean multiselect;
    public Integer rows;
    public String rerender;
    public String for_x;
    public Object appearRequired;
    public Object field;
    public Object sObjType;
  }

  public static final class Apex {
    private Apex() {}

    public static class OutputPanel extends Base {}

    public static class CommandButton extends Base {}

    public static class OutputText extends Base {}

    public static class OutputLabel extends Base {}

    public static class SelectList extends Base {}

    public static class SelectOptions extends Base {}

    public static class InputTextarea extends Base {}
  }

  public static final class c {
    private c() {}

    public static class UTIL_FormField extends Base {}
  }
}
