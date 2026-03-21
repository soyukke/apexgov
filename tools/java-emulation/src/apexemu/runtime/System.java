package apexemu.runtime;

import java.io.PrintWriter;
import java.io.StringWriter;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

public final class System {
  private System() {}

  public static final java.io.PrintStream out = java.lang.System.out;
  public static final java.io.PrintStream err = java.lang.System.err;

  /** Registry mapping lowercase simple class names to their loaded Class objects.
   *  Populated by Runner so that Type.forName() can resolve Apex class names case-insensitively. */
  private static final Map<String, Class<?>> classRegistry = new ConcurrentHashMap<>();

  public static void registerClass(String simpleName, Class<?> clazz) {
    if (simpleName != null && clazz != null) {
      classRegistry.put(simpleName.toLowerCase(), clazz);
    }
  }

  public static void clearClassRegistry() {
    classRegistry.clear();
  }

  static List<Class<?>> registeredClassesSnapshot() {
    return new ArrayList<>(classRegistry.values());
  }

  private static ClassLoader currentClassLoader(Class<?> fallbackOwner) {
    ClassLoader loader = Thread.currentThread().getContextClassLoader();
    if (loader == null && fallbackOwner != null) {
      loader = fallbackOwner.getClassLoader();
    }
    return loader;
  }

  private static List<String> nestedClassNameVariants(String name) {
    List<String> variants = new ArrayList<>();
    if (name == null || name.isBlank()) {
      return variants;
    }
    String trimmed = name.trim();
    variants.add(trimmed);
    String[] parts = trimmed.split("\\.");
    if (parts.length < 2) {
      return variants;
    }
    for (int packageSegments = 0; packageSegments < parts.length - 1; packageSegments += 1) {
      StringBuilder candidate = new StringBuilder();
      for (int i = 0; i < parts.length; i += 1) {
        if (i > 0) {
          candidate.append(i <= packageSegments ? '.' : '$');
        }
        candidate.append(parts[i]);
      }
      String text = candidate.toString();
      if (!variants.contains(text)) {
        variants.add(text);
      }
    }
    return variants;
  }

  private static Class<?> resolveRegisteredClass(String name) {
    if (name == null || name.isBlank()) {
      return null;
    }
    for (String candidate : nestedClassNameVariants(name)) {
      Class<?> registered = classRegistry.get(candidate.toLowerCase());
      if (registered != null) {
        return registered;
      }
    }
    return null;
  }

  private static Class<?> loadClassByVariants(ClassLoader loader, String name) {
    if (name == null || name.isBlank()) {
      return null;
    }
    for (String candidate : nestedClassNameVariants(name)) {
      try {
        return Class.forName(candidate, true, loader);
      } catch (ClassNotFoundException ignored) {
        // try next candidate
      }
    }
    return null;
  }

  private static Class<?> resolveRuntimeClass(String name, Class<?> fallbackOwner) {
    if (name == null || name.isBlank()) {
      return null;
    }
    Class<?> registered = resolveRegisteredClass(name);
    if (registered != null) {
      return registered;
    }

    ClassLoader loader = currentClassLoader(fallbackOwner);
    String[] prefixes = new String[] {"", "generated.", "apexemu.runtime.", "java.lang."};
    for (String prefix : prefixes) {
      Class<?> resolved = loadClassByVariants(loader, prefix + name);
      if (resolved != null) {
        return resolved;
      }
    }
    return null;
  }

  public static class Exception extends RuntimeException {
    private String message;

    public Exception() {
      super();
      this.message = null;
    }

    public Exception(String message) {
      super(message);
      this.message = message;
    }

    public Exception(String message, Throwable cause) {
      super(message, cause);
      this.message = message;
    }

    public void setMessage(String message) {
      this.message = message;
    }

    @Override
    public String getMessage() {
      return message != null ? message : super.getMessage();
    }

    public String getStackTraceString() {
      StringWriter writer = new StringWriter();
      PrintWriter printWriter = new PrintWriter(writer);
      this.printStackTrace(printWriter);
      printWriter.flush();
      return writer.toString();
    }

    public String getTypeName() {
      return this.getClass().getName();
    }
  }

  public static final class TypeException extends Exception {
    public TypeException(String message) {
      super(message);
    }

    public TypeException(String message, Throwable cause) {
      super(message, cause);
    }
  }

  public static final class IllegalArgumentException extends java.lang.IllegalArgumentException {
    public IllegalArgumentException(String message) {
      super(message);
    }
  }

  public static final class NullPointerException extends java.lang.NullPointerException {
    public NullPointerException() {
      super();
    }

    public NullPointerException(String message) {
      super(message);
    }
  }

  public static class QueryException extends Exception {
    private Map<String, Set<String>> inaccessibleFields;

    public QueryException() {
      super();
    }

    public QueryException(String message) {
      super(message);
    }

    public QueryException(String message, Throwable cause) {
      super(message, cause);
    }

    public Map<String, Set<String>> getInaccessibleFields() {
      return inaccessibleFields;
    }

    public void setInaccessibleFields(Map<String, Set<String>> inaccessibleFields) {
      this.inaccessibleFields = inaccessibleFields;
    }
  }

  public static class DmlException extends apexemu.runtime.DmlException {
    public DmlException() {
      super();
    }

    public DmlException(String message) {
      super(message);
    }

    public DmlException(String message, Throwable cause) {
      super(message, cause);
    }
  }

  public static class CalloutException extends Exception {
    public CalloutException() {
      super();
    }

    public CalloutException(String message) {
      super(message);
    }

    public CalloutException(String message, Throwable cause) {
      super(message, cause);
    }
  }

  public static final class NoAccessException extends Exception {
    public NoAccessException() {
      super();
    }

    public NoAccessException(String message) {
      super(message);
    }
  }

  public static class SecurityException extends Exception {
    public SecurityException() {
      super();
    }

    public SecurityException(String message) {
      super(message);
    }
  }

  public static class JSONException extends Exception {
    public JSONException() {
      super();
    }

    public JSONException(String message) {
      super(message);
    }

    public JSONException(String message, Throwable cause) {
      super(message, cause);
    }
  }

  public static final class FormulaValidationException extends Exception {
    public FormulaValidationException(String message) {
      super(message);
    }

    public FormulaValidationException(String message, Throwable cause) {
      super(message, cause);
    }
  }

  public static class AuraHandledException extends Exception {
    public AuraHandledException(String message) {
      super(message);
    }
  }

  public static PageReference currentPageReference() {
    return ApexPages.currentPage();
  }

  public static Long currentTimeMillis() {
    return java.lang.System.currentTimeMillis();
  }

  public static final class Date {
    private Date() {}

    public static apexemu.runtime.Date today() {
      return apexemu.runtime.Date.today();
    }
  }

  public static final class Crypto {
    private Crypto() {}

    public static Integer getRandomInteger() {
      return apexemu.runtime.Crypto.getRandomInteger();
    }

    public static Long getRandomLong() {
      return apexemu.runtime.Crypto.getRandomLong();
    }

    public static byte[] generateDigest(String algorithm, byte[] data) {
      return apexemu.runtime.Crypto.generateDigest(algorithm, data);
    }
  }

  public enum RoundingMode {
    HALF_UP(java.math.RoundingMode.HALF_UP),
    HALF_DOWN(java.math.RoundingMode.HALF_DOWN),
    CEILING(java.math.RoundingMode.CEILING),
    FLOOR(java.math.RoundingMode.FLOOR),
    DOWN(java.math.RoundingMode.DOWN),
    UP(java.math.RoundingMode.UP);

    private final java.math.RoundingMode javaMode;

    RoundingMode(java.math.RoundingMode javaMode) {
      this.javaMode = javaMode;
    }

    public java.math.RoundingMode toJavaMode() {
      return javaMode;
    }
  }

  public static final class ApexMath {
    private ApexMath() {}

    public static Integer mod(Integer left, Integer right) {
      return apexemu.runtime.ApexMath.mod(left, right);
    }

    public static Long mod(Long left, Long right) {
      return apexemu.runtime.ApexMath.mod(left, right);
    }
  }

  public static final class URL {
    private URL() {}

    public static apexemu.runtime.URL getOrgDomainUrl() {
      return apexemu.runtime.URL.getOrgDomainUrl();
    }

    public static apexemu.runtime.URL getSalesforceBaseUrl() {
      return apexemu.runtime.URL.getSalesforceBaseUrl();
    }
  }

  public static class SObjectException extends apexemu.runtime.SObjectException {
    public SObjectException(String message) {
      super(message);
    }
  }

  public interface Iterable<T> extends java.lang.Iterable<T> {}

  public interface Iterator<T> extends java.util.Iterator<T> {}

  public static final class RestRequest extends apexemu.runtime.RestRequest {}

  public static final class RestResponse extends apexemu.runtime.RestResponse {}

  public static final class Pattern {
    private Pattern() {}

    public static java.util.regex.Pattern compile(String regex) {
      return java.util.regex.Pattern.compile(regex == null ? "" : regex);
    }

    public static boolean matches(String regex, CharSequence input) {
      return java.util.regex.Pattern.matches(regex == null ? "" : regex, input == null ? "" : input);
    }
  }

  public interface StubProvider {
    default Object handleMethodCall(
        Object stubbedObject,
        String methodName,
        Type returnType,
        List<Type> paramTypes,
        List<String> paramNames,
        List<Object> args) {
      return null;
    }
  }

  public interface Comparable extends ApexComparable {}

  public interface Callable {
    default Object call(String action, Map<String, Object> args) {
      return null;
    }
  }

  public interface Finalizer {}

  public interface InstallHandler {}

  public interface UninstallHandler {}

  public interface HttpCalloutMock extends apexemu.runtime.HttpCalloutMock {}

  public static class InstallContext {
    public String installerID;
    private apexemu.runtime.Version previousVersion;
    private boolean upgrade;
    private boolean push;

    public InstallContext() {}

    public apexemu.runtime.Version previousVersion() {
      return previousVersion;
    }

    public boolean isUpgrade() {
      return upgrade;
    }

    public boolean isPush() {
      return push;
    }

    public String installerID() {
      if (installerID == null || installerID.isBlank()) {
        return UserInfo.getUserId();
      }
      return installerID;
    }

    public void setPreviousVersion(apexemu.runtime.Version previousVersion) {
      this.previousVersion = previousVersion;
    }

    public void setUpgrade(boolean upgrade) {
      this.upgrade = upgrade;
    }

    public void setPush(boolean push) {
      this.push = push;
    }
  }

  public static final class UninstallContext {}

  public static final class SavePoint {
    private final Database.Savepoint delegate;

    public SavePoint(Database.Savepoint delegate) {
      this.delegate = delegate;
    }

    public Database.Savepoint asDatabaseSavepoint() {
      return delegate;
    }
  }

  public static final class SelectOption {
    private final String value;
    private final String label;
    private final boolean disabled;

    public SelectOption(String value, String label) {
      this(value, label, false);
    }

    public SelectOption(String value, String label, boolean disabled) {
      this.value = value;
      this.label = label;
      this.disabled = disabled;
    }

    public String getValue() {
      return value;
    }

    public String getLabel() {
      return label;
    }

    public boolean getDisabled() {
      return disabled;
    }
  }

  public static class NoDataFoundException extends Exception {
    public NoDataFoundException() {
      super();
    }

    public NoDataFoundException(String message) {
      super(message);
    }
  }

  public static String requestVersion() {
    return "1.0";
  }

  public static boolean isFuture() {
    return false;
  }

  public static boolean isBatch() {
    return false;
  }

  public static boolean isQueueable() {
    return false;
  }

  public interface FinalizerContext {
    enum ParentJobResult {
      SUCCESS,
      UNHANDLED_EXCEPTION
    }

    default ParentJobResult getResult() {
      return ParentJobResult.SUCCESS;
    }

    default Exception getException() {
      return null;
    }

    default String getRequestId() {
      return null;
    }

    default String getAsyncApexJobId() {
      return null;
    }
  }

  public static final class JSON {
    private JSON() {}

    public static String serialize(Object value) {
      return apexemu.runtime.JSON.serialize(value);
    }

    public static String serializePretty(Object value) {
      return apexemu.runtime.JSON.serializePretty(value);
    }

    public static Object deserializeUntyped(String payload) {
      return apexemu.runtime.JSON.deserializeUntyped(payload);
    }

    @SuppressWarnings("unchecked")
    public static <T> T deserialize(String payload, Class<T> clazz) {
      if (clazz == null) {
        return null;
      }
      if (clazz == List.class) {
        Object untyped = apexemu.runtime.JSON.deserializeUntyped(payload);
        if (!(untyped instanceof List<?> rawList)) {
          return (T) untyped;
        }
        Class<?> elementClass = inferCallerListElementType();
        return (T) convertListElements(rawList, elementClass);
      }
      return apexemu.runtime.JSON.deserialize(payload, clazz);
    }

    @SuppressWarnings("unchecked")
    public static <T> T deserialize(String payload, Type type) {
      if (type == null) {
        return null;
      }
      String typeName = type.getName();
      if (typeName != null && typeName.equalsIgnoreCase("List")) {
        Object untyped = apexemu.runtime.JSON.deserializeUntyped(payload);
        if (!(untyped instanceof List<?> rawList)) {
          return (T) untyped;
        }
        Class<?> elementClass = inferCallerListElementType();
        return (T) convertListElements(rawList, elementClass);
      }

      Class<?> resolved = resolveClass(type);
      if (resolved == null) {
        return (T) apexemu.runtime.JSON.deserializeUntyped(payload);
      }
      return (T) apexemu.runtime.JSON.deserialize(payload, (Class<Object>) resolved);
    }

    public static <T> T deserializeStrict(String payload, Class<T> clazz) {
      return apexemu.runtime.JSON.deserializeStrict(payload, clazz);
    }

    private static Class<?> resolveClass(Type type) {
      String name = type.getName();
      if (name == null || name.isBlank()) {
        return null;
      }
      return resolveRuntimeClass(name, System.class);
    }

    private static Class<?> inferCallerListElementType() {
      StackTraceElement[] stack = Thread.currentThread().getStackTrace();
      if (stack == null || stack.length == 0) {
        return null;
      }
      ClassLoader cl = Thread.currentThread().getContextClassLoader();
      if (cl == null) {
        cl = System.class.getClassLoader();
      }
      String jsonClassName = System.class.getName() + "$JSON";
      for (StackTraceElement frame : stack) {
        if (frame == null) {
          continue;
        }
        String className = frame.getClassName();
        if (className == null
            || className.equals(jsonClassName)
            || className.equals(Thread.class.getName())) {
          continue;
        }
        try {
          Class<?> owner = Class.forName(className, true, cl);
          for (java.lang.reflect.Method method : owner.getDeclaredMethods()) {
            if (!method.getName().equals(frame.getMethodName())) {
              continue;
            }
            java.lang.reflect.Type genericReturn = method.getGenericReturnType();
            if (!(genericReturn instanceof java.lang.reflect.ParameterizedType parameterized)) {
              continue;
            }
            java.lang.reflect.Type raw = parameterized.getRawType();
            if (!(raw instanceof Class<?> rawClass)
                || !java.util.List.class.isAssignableFrom(rawClass)) {
              continue;
            }
            java.lang.reflect.Type[] args = parameterized.getActualTypeArguments();
            if (args == null || args.length != 1) {
              continue;
            }
            Class<?> resolved = extractClass(args[0]);
            if (resolved != null) {
              return resolved;
            }
          }
        } catch (ClassNotFoundException ignored) {
          // try next caller frame
        }
      }
      return null;
    }

    @SuppressWarnings("unchecked")
    private static List<Object> convertListElements(List<?> rawList, Class<?> elementClass) {
      if (rawList == null || rawList.isEmpty()) {
        return List.of();
      }
      if (elementClass == null || elementClass == Object.class) {
        return new ArrayList<>(rawList);
      }
      List<Object> converted = new ArrayList<>(rawList.size());
      for (Object raw : rawList) {
        if (raw == null || elementClass.isInstance(raw)) {
          converted.add(raw);
          continue;
        }
        try {
          Object mapped =
              apexemu.runtime.JSON.deserialize(
                  apexemu.runtime.JSON.serialize(raw), (Class<Object>) elementClass);
          converted.add(mapped);
        } catch (RuntimeException ignored) {
          converted.add(raw);
        }
      }
      return converted;
    }

    private static Class<?> extractClass(java.lang.reflect.Type type) {
      if (type instanceof Class<?> klass) {
        return klass;
      }
      if (type instanceof java.lang.reflect.ParameterizedType parameterized
          && parameterized.getRawType() instanceof Class<?> raw) {
        return raw;
      }
      return null;
    }
  }

  public static final class Test {
    private Test() {}

    public static boolean isRunningTest() {
      return apexemu.runtime.Test.isRunningTest();
    }

    public static void startTest() {
      apexemu.runtime.Test.startTest();
    }

    public static void stopTest() {
      apexemu.runtime.Test.stopTest();
    }

    public static void setCurrentPage(PageReference pageReference) {
      apexemu.runtime.Test.setCurrentPage(pageReference);
    }

    public static void calculatePermissionSetGroup(Object permissionSetGroupId) {
      apexemu.runtime.Test.calculatePermissionSetGroup(permissionSetGroupId);
    }

    public static apexemu.runtime.Test.EventBusController getEventBus() {
      return apexemu.runtime.Test.getEventBus();
    }
  }

  public static final class Type {
    private final String typeName;

    private Type(String typeName) {
      if (typeName == null || typeName.isBlank()) {
        throw new TypeException("type name cannot be blank");
      }
      this.typeName = typeName.trim();
    }

    public static Type forName(String typeName) {
      if (typeName == null || typeName.isBlank()) {
        throw new TypeException("type name cannot be blank");
      }
      return forResolvedName(typeName.trim());
    }

    public static Type forName(String namespace, String typeName) {
      if (typeName == null || typeName.isBlank()) {
        throw new TypeException("type name cannot be blank");
      }
      String normalizedName = typeName.trim();
      if (namespace == null || namespace.isBlank()) {
        return forResolvedName(normalizedName);
      }
      return forResolvedName(namespace.trim() + "." + normalizedName);
    }

    public String getName() {
      return typeName;
    }

    public Object newInstance() {
      if (isListType(typeName)) {
        return new ArrayList<>();
      }
      if (isSetType(typeName)) {
        return new java.util.LinkedHashSet<>();
      }
      if (isMapType(typeName)) {
        return new LinkedHashMap<>();
      }
      Object sObjectFallback = instantiateSObjectFallback(typeName);
      if (sObjectFallback != null) {
        return sObjectFallback;
      }
      Class<?> klass = resolveClass(typeName);
      if (klass == null) {
        String normalizedApexName = normalizeApexSimpleTypeName(typeName);
        if (!normalizedApexName.equals(typeName)) {
          klass = resolveClass(normalizedApexName);
        }
      }
      if (klass == null) {
        throw new TypeException("failed to instantiate type: " + typeName);
      }
      try {
        java.lang.reflect.Constructor<?> ctor = klass.getDeclaredConstructor();
        ctor.setAccessible(true);
        return ctor.newInstance();
      } catch (NoSuchMethodException ignored) {
        return instantiateWithFallbackConstructor(klass);
      } catch (ReflectiveOperationException ex) {
        throw new TypeException("failed to instantiate type: " + typeName, ex);
      }
    }

    private static Type forResolvedName(String normalized) {
      if (normalized == null || normalized.isBlank()) {
        return null;
      }
      String candidate = normalized.trim();
      // SObject is the Apex base type for all database records.
      if (candidate.equalsIgnoreCase("SObject") || candidate.equalsIgnoreCase("ApexSObject")) {
        return new Type("SObject");
      }
      if (isKnownSObjectTypeToken(candidate)) {
        return new Type(candidate);
      }
      if (isListType(candidate) || isSetType(candidate) || isMapType(candidate)) {
        return new Type(candidate);
      }
      Class<?> resolved = resolveClass(candidate);
      if (resolved != null) {
        return new Type(resolved.getName());
      }
      String apexStyle = normalizeApexSimpleTypeName(candidate);
      if (isKnownSObjectTypeToken(apexStyle)) {
        return new Type(apexStyle);
      }
      if (isListType(apexStyle) || isSetType(apexStyle) || isMapType(apexStyle)) {
        return new Type(apexStyle);
      }
      resolved = resolveClass(apexStyle);
      if (resolved != null) {
        return new Type(resolved.getName());
      }
      return null;
    }

    private static String normalizeApexSimpleTypeName(String normalized) {
      if (normalized == null || normalized.isBlank()) {
        return "";
      }
      String trimmed = normalized.trim();
      if (trimmed.indexOf('.') >= 0) {
        return trimmed;
      }
      if (!Character.isLowerCase(trimmed.charAt(0))) {
        return trimmed;
      }
      if (!Character.isLetter(trimmed.charAt(0))) {
        return trimmed;
      }
      return Character.toUpperCase(trimmed.charAt(0)) + trimmed.substring(1);
    }

    private static boolean isListType(String normalized) {
      return equalsTypeToken(normalized, "List") || startsWithType(normalized, "List<");
    }

    private static boolean isSetType(String normalized) {
      return equalsTypeToken(normalized, "Set") || startsWithType(normalized, "Set<");
    }

    private static boolean isMapType(String normalized) {
      return equalsTypeToken(normalized, "Map") || startsWithType(normalized, "Map<");
    }

    private static boolean startsWithType(String normalized, String prefix) {
      if (normalized == null || prefix == null) {
        return false;
      }
      String trimmed = normalized.trim();
      if (!trimmed.endsWith(">") || trimmed.length() <= prefix.length()) {
        return false;
      }
      return trimmed.regionMatches(true, 0, prefix, 0, prefix.length());
    }

    private static boolean equalsTypeToken(String normalized, String token) {
      if (normalized == null || token == null) {
        return false;
      }
      String trimmed = normalized.trim();
      if (trimmed.isEmpty()) {
        return false;
      }
      return trimmed.equalsIgnoreCase(token);
    }

    private static Object instantiateSObjectFallback(String rawTypeName) {
      if (rawTypeName == null || rawTypeName.isBlank()) {
        return null;
      }
      String normalized = rawTypeName.trim();
      Schema.SObjectType fromDescribe = lookupSObjectType(normalized);
      if (fromDescribe != null) {
        return fromDescribe.newSObject();
      }
      if (isLikelyCustomSObjectTypeToken(normalized)) {
        return new Schema.SObjectType(normalized).newSObject();
      }
      return null;
    }

    private static boolean isKnownSObjectTypeToken(String typeName) {
      if (typeName == null || typeName.isBlank()) {
        return false;
      }
      return lookupSObjectType(typeName) != null || isLikelyCustomSObjectTypeToken(typeName);
    }

    private static Schema.SObjectType lookupSObjectType(String typeName) {
      if (typeName == null || typeName.isBlank()) {
        return null;
      }
      String normalized = typeName.trim();
      Map<String, Schema.SObjectType> describe = Schema.getGlobalDescribe();
      Schema.SObjectType byName = describe.get(normalized);
      if (byName != null) {
        return byName;
      }
      return describe.get(normalized.toLowerCase(Locale.ROOT));
    }

    private static boolean isLikelyCustomSObjectTypeToken(String typeName) {
      if (typeName == null || typeName.isBlank()) {
        return false;
      }
      String normalized = typeName.trim().toLowerCase(Locale.ROOT);
      return normalized.endsWith("__c")
          || normalized.endsWith("__mdt")
          || normalized.endsWith("__e")
          || normalized.endsWith("__b")
          || normalized.endsWith("__x");
    }

    private Object instantiateWithFallbackConstructor(Class<?> klass) {
      java.lang.reflect.Constructor<?>[] constructors = klass.getDeclaredConstructors();
      if (constructors == null || constructors.length == 0) {
        throw new TypeException("failed to instantiate type: " + typeName);
      }

      java.util.Arrays.sort(
          constructors,
          (left, right) -> Integer.compare(left.getParameterCount(), right.getParameterCount()));

      for (java.lang.reflect.Constructor<?> ctor : constructors) {
        try {
          ctor.setAccessible(true);
          Class<?>[] parameterTypes = ctor.getParameterTypes();
          Object[] args = new Object[parameterTypes.length];
          for (int i = 0; i < parameterTypes.length; i += 1) {
            args[i] = defaultValueFor(parameterTypes[i]);
          }
          return ctor.newInstance(args);
        } catch (ReflectiveOperationException ignored) {
          // try next constructor shape
        }
      }
      throw new TypeException("failed to instantiate type: " + typeName);
    }

    private static Object defaultValueFor(Class<?> parameterType) {
      if (parameterType == null || !parameterType.isPrimitive()) {
        return null;
      }
      if (parameterType == boolean.class) {
        return Boolean.FALSE;
      }
      if (parameterType == char.class) {
        return Character.valueOf('\0');
      }
      if (parameterType == byte.class) {
        return Byte.valueOf((byte) 0);
      }
      if (parameterType == short.class) {
        return Short.valueOf((short) 0);
      }
      if (parameterType == int.class) {
        return Integer.valueOf(0);
      }
      if (parameterType == long.class) {
        return Long.valueOf(0L);
      }
      if (parameterType == float.class) {
        return Float.valueOf(0F);
      }
      if (parameterType == double.class) {
        return Double.valueOf(0D);
      }
      return null;
    }

    private static boolean isLikelyApexTypeToken(String normalized) {
      if (normalized == null || normalized.isBlank()) {
        return false;
      }

      int dot = normalized.indexOf('.');
      if (dot < 0) {
        return Character.isUpperCase(normalized.charAt(0));
      }
      if (dot == 0) {
        return false;
      }
      String namespace = normalized.substring(0, dot);
      return isBuiltInNamespace(namespace);
    }

    private static boolean isBuiltInNamespace(String namespace) {
      if (namespace == null || namespace.isBlank()) {
        return false;
      }
      String lowered = namespace.toLowerCase();
      return lowered.equals("system")
          || lowered.equals("schema")
          || lowered.equals("database")
          || lowered.equals("messaging")
          || lowered.equals("connectapi")
          || lowered.equals("cache")
          || lowered.equals("json")
          || lowered.equals("crypto")
          || lowered.equals("limits")
          || lowered.equals("userinfo")
          || lowered.equals("network")
          || lowered.equals("visualeditor")
          || lowered.equals("apexpages");
    }

    private static Class<?> resolveClass(String name) {
      if (name == null || name.isBlank()) {
        return null;
      }
      // Prefer runner-registered classes to avoid loading the same generated type from a different classloader.
      return resolveRuntimeClass(name, Type.class);
    }

    @Override
    public boolean equals(Object other) {
      if (this == other) {
        return true;
      }
      if (other instanceof Class<?> thatClass) {
        Class<?> resolved = resolveClass(this.typeName);
        if (resolved != null) {
          return resolved.equals(thatClass);
        }
        return normalizeTypeIdentity(this.typeName).equalsIgnoreCase(normalizeTypeIdentity(thatClass.getName()));
      }
      if (!(other instanceof Type that)) {
        return false;
      }
      Class<?> thisResolved = resolveClass(this.typeName);
      Class<?> thatResolved = resolveClass(that.typeName);
      if (thisResolved != null && thatResolved != null) {
        return thisResolved.equals(thatResolved);
      }
      return normalizeTypeIdentity(this.typeName).equalsIgnoreCase(normalizeTypeIdentity(that.typeName));
    }

    @Override
    public int hashCode() {
      return normalizeTypeIdentity(this.typeName).toLowerCase(java.util.Locale.ROOT).hashCode();
    }

    @Override
    public String toString() {
      String normalized = normalizeTypeIdentity(typeName);
      if (normalized.startsWith("java.lang.")) {
        return normalized.substring("java.lang.".length());
      }
      if (normalized.startsWith("generated.")) {
        return normalized.substring("generated.".length());
      }
      return normalized;
    }

    private static String normalizeTypeIdentity(String value) {
      if (value == null || value.isBlank()) {
        return "";
      }
      return value.trim().replace('$', '.');
    }
  }

  public enum LoggingLevel {
    ERROR,
    WARN,
    INFO,
    DEBUG,
    TRACE
  }

  public enum AccessType {
    CREATABLE,
    READABLE,
    UPDATABLE,
    UPSERTABLE
  }

  public enum AccessLevel {
    SYSTEM_MODE,
    USER_MODE
  }

  public static final class OrgLimit {
    private final Integer limit;
    private final Integer used;

    public OrgLimit(Integer limit, Integer used) {
      this.limit = limit == null ? 0 : limit;
      this.used = used == null ? 0 : used;
    }

    public Integer getLimit() {
      return limit;
    }

    public Integer getUsed() {
      return used;
    }

    public Integer getRemaining() {
      return Math.max(0, limit - used);
    }
  }

  public enum TriggerOperation {
    BEFORE_INSERT,
    BEFORE_UPDATE,
    BEFORE_DELETE,
    AFTER_INSERT,
    AFTER_UPDATE,
    AFTER_DELETE,
    AFTER_UNDELETE
  }

  public enum Quiddity {
    SYNCHRONOUS,
    FUTURE,
    QUEUEABLE,
    BATCH_APEX,
    RUNTEST_SYNC,
    RUNTEST_ASYNC,
    RUNTEST_DEPLOY,
    AURA,
    DISCOVERABLE_LOGIN,
    INBOUND_EMAIL_SERVICE,
    INVOCABLE_ACTION,
    IOT,
    QUICK_ACTION,
    REMOTE_ACTION,
    REST,
    SOAP,
    VF,
    UNKNOWN
  }

  public static final class Request {
    private static final ThreadLocal<Request> CURRENT = ThreadLocal.withInitial(Request::new);

    private Quiddity quiddity = Quiddity.UNKNOWN;
    private final String requestId = UUID.randomUUID().toString();

    public static Request getCurrent() {
      return CURRENT.get();
    }

    public Quiddity getQuiddity() {
      return quiddity;
    }

    public void setQuiddity(Quiddity quiddity) {
      this.quiddity = quiddity == null ? Quiddity.UNKNOWN : quiddity;
    }

    public String getRequestId() {
      return requestId;
    }

    public static void setCurrentQuiddity(Quiddity quiddity) {
      getCurrent().setQuiddity(quiddity);
    }
  }

  public static final class QueueableContext {
    private final String jobId;

    public QueueableContext(String jobId) {
      this.jobId = jobId == null ? "" : jobId;
    }

    public String getJobId() {
      return jobId;
    }
  }

  public static final class SchedulableContext {
    private final String triggerId;

    public SchedulableContext(String triggerId) {
      this.triggerId = triggerId == null ? "" : triggerId;
    }

    public String getTriggerId() {
      return triggerId;
    }
  }

  public static final class SObjectAccessDecision {
    private final List<ApexSObject> records;
    private final Map<String, Set<String>> removedFields;

    public SObjectAccessDecision(List<ApexSObject> records) {
      this(records, new LinkedHashMap<>());
    }

    public SObjectAccessDecision(List<ApexSObject> records, Map<String, Set<String>> removedFields) {
      this.records = copyRecords(records);
      this.removedFields = removedFields == null ? new LinkedHashMap<>() : new LinkedHashMap<>(removedFields);
    }

    public List<ApexSObject> getRecords() {
      return copyRecords(records);
    }

    public Map<String, Set<String>> getRemovedFields() {
      return new LinkedHashMap<>(removedFields);
    }

    private static List<ApexSObject> copyRecords(List<ApexSObject> source) {
      if (source == null || source.isEmpty()) {
        return new ArrayList<>();
      }
      List<ApexSObject> out = new ArrayList<>(source.size());
      for (ApexSObject row : source) {
        out.add(row == null ? null : row.copy());
      }
      return out;
    }
  }

  public static String enqueueJob(Queueable job) {
    return Async.enqueueQueueable(job);
  }

  public static String enqueueJob(Runnable job) {
    if (job == null) {
      throw new IllegalArgumentException("queueable job cannot be null");
    }
    return enqueueJob(
        new Queueable() {
          public void execute(System.QueueableContext context) {
            job.run();
          }

          public void execute() {
            job.run();
          }
        });
  }

  public static String schedule(String name, String cronExpr, Schedulable job) {
    if (name == null || name.isBlank()) {
      throw new IllegalArgumentException("schedule name cannot be blank");
    }
    if (cronExpr == null || cronExpr.isBlank()) {
      throw new IllegalArgumentException("cron expression cannot be blank");
    }
    String jobId = Async.enqueueSchedulable(job);
    try {
      ApexSObject cronTrigger =
          ApexSObject.of("CronTrigger")
              .withId(jobId)
              .set("CronExpression", cronExpr)
              .set("TimesTriggered", 0)
              .set("CronJobDetail", ApexSObject.of("CronJobDetail").set("Name", name))
              .set("NextFireTime", inferCronNextFireTime(cronExpr));
      Database.insert(cronTrigger);
    } catch (RuntimeException ignored) {
      // best effort: scheduled jobs can execute even when metadata persistence is unavailable
    }
    return jobId;
  }

  public static String schedule(String name, String cronExpr, Runnable job) {
    if (job == null) {
      throw new IllegalArgumentException("schedulable job cannot be null");
    }
    return schedule(
        name,
        cronExpr,
        new Schedulable() {
          @Override
          public void execute() {
            job.run();
          }
        });
  }

  public static apexemu.runtime.Date today() {
    return apexemu.runtime.Date.today();
  }

  public static DateTime now() {
    return DateTime.now();
  }

  public static DateTime Now() {
    return now();
  }

  public static boolean isScheduled() {
    return false;
  }

  public static void abortJob(String jobId) {
    // No-op in local emulation.
  }

  public static void abortJob(Object jobId) {
    abortJob(jobId == null ? null : String.valueOf(jobId));
  }

  public static void attachFinalizer(Finalizer finalizer) {
    // No-op in local emulation.
  }

  private static String inferCronNextFireTime(String cronExpr) {
    if (cronExpr == null || cronExpr.isBlank()) {
      return null;
    }
    String[] parts = cronExpr.trim().split("\\s+");
    if (parts.length < 6) {
      return null;
    }
    // Apex CRON: second minute hour dayOfMonth month dayOfWeek [year]
    String second = parts[0];
    String minute = parts[1];
    String hour = parts[2];
    String dayOfMonth = parts[3];
    String month = parts[4];
    String year = parts.length >= 7 ? parts[6] : "2099";
    if (!isNumericCronToken(second)
        || !isNumericCronToken(minute)
        || !isNumericCronToken(hour)
        || !isNumericCronToken(dayOfMonth)
        || !isNumericCronToken(month)
        || !isNumericCronToken(year)) {
      return null;
    }
    return java.lang.String.format(
        "%04d-%02d-%02d %02d:%02d:%02d",
        java.lang.Integer.parseInt(year),
        java.lang.Integer.parseInt(month),
        java.lang.Integer.parseInt(dayOfMonth),
        java.lang.Integer.parseInt(hour),
        java.lang.Integer.parseInt(minute),
        java.lang.Integer.parseInt(second));
  }

  private static boolean isNumericCronToken(String token) {
    if (token == null || token.isBlank()) {
      return false;
    }
    for (int i = 0; i < token.length(); i += 1) {
      if (!Character.isDigit(token.charAt(i))) {
        return false;
      }
    }
    return true;
  }
}
