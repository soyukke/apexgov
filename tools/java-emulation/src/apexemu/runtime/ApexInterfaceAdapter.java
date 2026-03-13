package apexemu.runtime;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;

public final class ApexInterfaceAdapter {
  private ApexInterfaceAdapter() {}

  public static <T> T adapt(Object target, Class<T> interfaceType) {
    if (target == null || interfaceType == null) {
      return null;
    }
    if (interfaceType.isInstance(target)) {
      return interfaceType.cast(target);
    }
    if (!interfaceType.isInterface()) {
      throw new ClassCastException("Cannot adapt to non-interface type: " + interfaceType.getName());
    }
    Object proxy =
        Proxy.newProxyInstance(
            interfaceType.getClassLoader(),
            new Class<?>[] {interfaceType},
            (p, method, args) -> invoke(target, method, args));
    return interfaceType.cast(proxy);
  }

  private static Object invoke(Object target, Method requestedMethod, Object[] args) throws Throwable {
    if (requestedMethod.getDeclaringClass() == Object.class) {
      switch (requestedMethod.getName()) {
        case "toString":
          return target.toString();
        case "hashCode":
          return target.hashCode();
        case "equals":
          return args != null && args.length == 1 && target.equals(args[0]);
        default:
          break;
      }
    }
    Method targetMethod = findCompatibleMethod(target.getClass(), requestedMethod);
    if (targetMethod == null) {
      throw new ClassCastException(
          target.getClass().getName()
              + " cannot be adapted to "
              + requestedMethod.getDeclaringClass().getName()
              + " (missing method "
              + requestedMethod.getName()
              + ")");
    }
    targetMethod.setAccessible(true);
    try {
      return targetMethod.invoke(target, args);
    } catch (InvocationTargetException error) {
      throw error.getCause();
    }
  }

  private static Method findCompatibleMethod(Class<?> targetType, Method requestedMethod) {
    Class<?> current = targetType;
    Class<?>[] expectedParams = requestedMethod.getParameterTypes();
    while (current != null) {
      for (Method method : current.getDeclaredMethods()) {
        if (!method.getName().equals(requestedMethod.getName())) {
          continue;
        }
        if (!parametersMatch(expectedParams, method.getParameterTypes())) {
          continue;
        }
        return method;
      }
      current = current.getSuperclass();
    }
    return null;
  }

  private static boolean parametersMatch(Class<?>[] expected, Class<?>[] actual) {
    if (expected.length != actual.length) {
      return false;
    }
    for (int i = 0; i < expected.length; i++) {
      Class<?> expectedType = box(expected[i]);
      Class<?> actualType = box(actual[i]);
      if (!expectedType.isAssignableFrom(actualType)) {
        return false;
      }
    }
    return true;
  }

  private static Class<?> box(Class<?> type) {
    if (!type.isPrimitive()) {
      return type;
    }
    if (type == boolean.class) {
      return Boolean.class;
    }
    if (type == byte.class) {
      return Byte.class;
    }
    if (type == short.class) {
      return Short.class;
    }
    if (type == int.class) {
      return Integer.class;
    }
    if (type == long.class) {
      return Long.class;
    }
    if (type == float.class) {
      return Float.class;
    }
    if (type == double.class) {
      return Double.class;
    }
    if (type == char.class) {
      return Character.class;
    }
    return type;
  }
}
