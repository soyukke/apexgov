package apexemu.runtime;

import java.io.IOException;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.lang.reflect.Proxy;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import javax.tools.JavaCompiler;
import javax.tools.StandardJavaFileManager;
import javax.tools.ToolProvider;

public final class Test {
  private static final ThreadLocal<Map<Class<?>, Object>> MOCKS =
      ThreadLocal.withInitial(HashMap::new);
  private static final ThreadLocal<List<String>> FIXED_SEARCH_RESULTS =
      ThreadLocal.withInitial(List::of);
  private static final ThreadLocal<EventBusController> EVENT_BUS =
      ThreadLocal.withInitial(EventBusController::new);
  private static final ThreadLocal<Integer> RUN_AS_SEQUENCE =
      ThreadLocal.withInitial(() -> 0);
  private static final ThreadLocal<Boolean> SEE_ALL_DATA =
      ThreadLocal.withInitial(() -> Boolean.FALSE);

  private static final ThreadLocal<Map<Object, System.StubProvider>> STUB_PROVIDERS =
      ThreadLocal.withInitial(IdentityHashMap::new);
  private static final ThreadLocal<Map<Class<?>, Constructor<?>>> STUB_CONSTRUCTOR_CACHE =
      ThreadLocal.withInitial(HashMap::new);

  private static final Object NO_STUB_MATCH = new Object();

  private Test() {}

  public static void startTest() {
    Async.startTestWindow();
    EventBus.resetForTestWindow();
    Limits.startTest();
  }

  public static void StartTest() {
    startTest();
  }

  public static void starttest() {
    startTest();
  }

  public static void stopTest() {
    Async.flush();
    EventBus.flushPending();
    Limits.stopTest();
  }

  public static void StopTest() {
    stopTest();
  }

  public static void stoptest() {
    stopTest();
  }

  public static String enqueueFuture(Runnable task) {
    return Async.enqueueFuture(task);
  }

  public static String enqueueFutureMethod(Class<?> owner, String methodName) {
    return Async.enqueueFutureMethod(owner, methodName);
  }

  public static Async.Snapshot getAsyncSnapshot() {
    return Async.snapshot();
  }

  public static boolean isRunningTest() {
    return true;
  }

  public static void setCurrentPage(PageReference pageReference) {
    ApexPages.setCurrentPage(pageReference);
  }

  public static void setCurrentPageReference(PageReference pageReference) {
    setCurrentPage(pageReference);
  }

  public static void setCreatedDate(Object record, DateTime createdDate) {
    ApexSObject row = record instanceof ApexSObject ? (ApexSObject) record : null;
    if (row == null) {
      return;
    }
    row.set("CreatedDate", createdDate == null ? null : createdDate.toString());
  }

  public static void testInstall(System.InstallHandler handler, apexemu.runtime.Version previousVersion) {
    testInstall(handler, previousVersion, false);
  }

  public static void testInstall(
      System.InstallHandler handler, apexemu.runtime.Version previousVersion, boolean isPush) {
    if (handler == null) {
      return;
    }
    System.InstallContext context = new System.InstallContext();
    context.setPreviousVersion(previousVersion);
    context.setPush(isPush);
    context.setUpgrade(previousVersion != null && !isPush);
    try {
      Method method = handler.getClass().getMethod("onInstall", System.InstallContext.class);
      method.setAccessible(true);
      method.invoke(handler, context);
    } catch (NoSuchMethodException ignored) {
      // Install handlers are optional in local emulation.
    } catch (IllegalAccessException | InvocationTargetException ignored) {
      // Best-effort only.
    }
  }

  public static void testUninstall(System.UninstallHandler handler) {
    if (handler == null) {
      return;
    }
    try {
      Method method = handler.getClass().getMethod("onUninstall", System.UninstallContext.class);
      method.setAccessible(true);
      method.invoke(handler, new System.UninstallContext());
    } catch (NoSuchMethodException ignored) {
      // Uninstall handlers are optional in local emulation.
    } catch (IllegalAccessException | InvocationTargetException ignored) {
      // Best-effort only.
    }
  }

  public static void runAs(ApexSObject user, Runnable work) {
    if (user == null) {
      throw new IllegalArgumentException("runAs user cannot be null");
    }
    if (work == null) {
      throw new IllegalArgumentException("runAs work cannot be null");
    }
    String userId = ensureRunAsUserId(user);
    UserContext.runAs(userId, user, () -> Schema.runAs(user, work));
  }

  // Stack-based runAs for transpiled code (avoids lambda variable capture issues)
  private static final ThreadLocal<java.util.ArrayDeque<RunAsFrame>> RUNAS_STACK =
      ThreadLocal.withInitial(java.util.ArrayDeque::new);

  private static class RunAsFrame {
    final String previousUserId;
    final ApexSObject previousUser;
    final String previousProfileId;

    RunAsFrame(String userId, ApexSObject user, String profileId) {
      this.previousUserId = userId;
      this.previousUser = user;
      this.previousProfileId = profileId;
    }
  }

  public static void beginRunAs(ApexSObject user) {
    if (user == null) {
      throw new IllegalArgumentException("runAs user cannot be null");
    }
    ensureRunAsUserId(user);
    // Save current state
    RunAsFrame frame =
        new RunAsFrame(UserContext.currentUserId(), UserContext.currentUser(), Schema.getCurrentProfileId());
    RUNAS_STACK.get().push(frame);
    // Switch context
    UserContext.setCurrentUser(user);
    String profileId = null;
    Object rawProfileId = user.get("ProfileId");
    if (rawProfileId == null) rawProfileId = user.get("profileId");
    if (rawProfileId != null) {
      String value = String.valueOf(rawProfileId).trim();
      if (!value.isEmpty()) {
        profileId = value;
      }
    }
    Schema.setCurrentProfileId(profileId);
  }

  private static String ensureRunAsUserId(ApexSObject user) {
    String userId = user == null ? null : user.id();
    if (userId != null && !userId.isBlank()) {
      return userId;
    }
    int seq = RUN_AS_SEQUENCE.get() + 1;
    RUN_AS_SEQUENCE.set(seq);
    String syntheticId = String.format("005RUNAS%09d", seq);
    if (user != null) {
      user.withId(syntheticId);
    }
    return syntheticId;
  }

  public static void endRunAs() {
    java.util.ArrayDeque<RunAsFrame> stack = RUNAS_STACK.get();
    if (stack.isEmpty()) return;
    RunAsFrame frame = stack.pop();
    if (frame.previousUser != null) {
      UserContext.setCurrentUser(frame.previousUser);
    } else {
      UserContext.setCurrentUserId(frame.previousUserId);
    }
    Schema.setCurrentProfileId(frame.previousProfileId);
  }

  public static List<ApexSObject> loadData(String sobjectType, String csvPath) {
    return TestData.loadData(sobjectType, csvPath);
  }

  public static <T> void setMock(Class<T> mockType, T mockImpl) {
    if (mockType == null) {
      throw new IllegalArgumentException("mockType cannot be null");
    }
    if (mockImpl == null) {
      throw new IllegalArgumentException("mock implementation cannot be null");
    }
    if (!mockType.isInstance(mockImpl)) {
      throw new IllegalArgumentException(
          "mock implementation type mismatch: expected " + mockType.getSimpleName());
    }
    MOCKS.get().put(mockType, mockImpl);
  }

  public static void setMock(System.Type mockType, Object mockImpl) {
    if (mockType == null) {
      throw new IllegalArgumentException("mockType cannot be null");
    }
    Class<?> resolved = resolveTypeClass(mockType);
    if (resolved == null) {
      throw new IllegalArgumentException("unsupported mock type: " + mockType.getName());
    }
    if (mockImpl == null) {
      throw new IllegalArgumentException("mock implementation cannot be null");
    }
    if (!resolved.isInstance(mockImpl)) {
      throw new IllegalArgumentException(
          "mock implementation type mismatch: expected " + resolved.getSimpleName());
    }
    MOCKS.get().put(resolved, mockImpl);
  }

  public static void setFixedSearchResults(List<String> recordIds) {
    if (recordIds == null || recordIds.isEmpty()) {
      FIXED_SEARCH_RESULTS.set(List.of());
      return;
    }
    FIXED_SEARCH_RESULTS.set(List.copyOf(recordIds));
  }

  public static void clearMocks() {
    MOCKS.get().clear();
    FIXED_SEARCH_RESULTS.set(List.of());
    STUB_PROVIDERS.get().clear();
    STUB_CONSTRUCTOR_CACHE.get().clear();
    EventBus.resetForTestWindow();
    SEE_ALL_DATA.set(Boolean.FALSE);
  }

  public static void setSeeAllDataEnabled(boolean enabled) {
    SEE_ALL_DATA.set(enabled);
  }

  public static boolean isSeeAllDataEnabled() {
    return Boolean.TRUE.equals(SEE_ALL_DATA.get());
  }

  public static String getStandardPricebookId() {
    return "01s000000000001AAA";
  }

  static <T> T getMock(Class<T> mockType) {
    if (mockType == null) {
      return null;
    }
    Object value = MOCKS.get().get(mockType);
    if (value == null) {
      return null;
    }
    return mockType.cast(value);
  }

  private static Class<?> resolveTypeClass(System.Type type) {
    if (type == null || type.getName() == null || type.getName().isBlank()) {
      return null;
    }
    String normalized = type.getName().trim();
    String[] candidates = {
      normalized,
      normalized.replace('.', '$'),
      "generated." + normalized,
      "generated." + normalized.replace('.', '$'),
      "apexemu.runtime." + normalized,
      "apexemu.runtime." + normalized.replace('.', '$')
    };
    ClassLoader cl = Thread.currentThread().getContextClassLoader();
    if (cl == null) {
      cl = Test.class.getClassLoader();
    }
    for (String candidate : candidates) {
      try {
        return Class.forName(candidate, true, cl);
      } catch (ClassNotFoundException ignored) {
        // try next candidate
      }
    }
    return null;
  }

  static List<String> getFixedSearchResults() {
    return FIXED_SEARCH_RESULTS.get();
  }

  @SuppressWarnings("unchecked")
  public static <T> T createStub(System.Type type, System.StubProvider provider) {
    if (type == null) {
      throw new IllegalArgumentException("type cannot be null");
    }

    Class<?> resolved = resolveTypeClass(type);
    if (resolved != null) {
      return (T) createStubForClass(resolved, provider);
    }

    Object instance = type.newInstance();
    if (instance != null && provider != null) {
      System.StubProvider effective = adaptStubProvider(provider);
      if (!attachLegacyStubProvider(instance, effective)) {
        STUB_PROVIDERS.get().put(instance, effective);
      }
    }
    return (T) instance;
  }

  public static <T> T createStub(Class<T> type, System.StubProvider provider) {
    if (type == null) {
      throw new IllegalArgumentException("type cannot be null");
    }
    return type.cast(createStubForClass(type, provider));
  }

  private static Object createStubForClass(Class<?> type, System.StubProvider provider) {
    if (type == null) {
      return null;
    }

    if (provider == null) {
      return instantiateType(type);
    }

    System.StubProvider effectiveProvider = adaptStubProvider(provider);
    if (type.isInterface()) {
      return createInterfaceStub(type, effectiveProvider);
    }

    Object subclassStub = instantiateDynamicSubclass(type, effectiveProvider);
    if (subclassStub != null) {
      return subclassStub;
    }

    Object fallback = instantiateType(type);
    if (fallback != null) {
      if (!attachLegacyStubProvider(fallback, effectiveProvider)) {
        STUB_PROVIDERS.get().put(fallback, effectiveProvider);
      }
    }
    return fallback;
  }

  private static System.StubProvider adaptStubProvider(System.StubProvider provider) {
    if (provider == null || provider instanceof DelegatingStubProvider) {
      return provider;
    }
    return new DelegatingStubProvider(provider);
  }

  private static Object instantiateType(Class<?> type) {
    try {
      Constructor<?> ctor = type.getDeclaredConstructor();
      ctor.setAccessible(true);
      return ctor.newInstance();
    } catch (NoSuchMethodException ignored) {
      return instantiateWithFallbackConstructor(type);
    } catch (ReflectiveOperationException error) {
      throw new IllegalStateException("failed to instantiate type: " + type.getName(), error);
    }
  }

  private static Object instantiateWithFallbackConstructor(Class<?> type) {
    Constructor<?>[] constructors = type.getDeclaredConstructors();
    if (constructors == null || constructors.length == 0) {
      throw new IllegalStateException("failed to instantiate type: " + type.getName());
    }
    Arrays.sort(constructors, (left, right) -> Integer.compare(left.getParameterCount(), right.getParameterCount()));
    for (Constructor<?> ctor : constructors) {
      try {
        ctor.setAccessible(true);
        Object[] args = defaultArgs(ctor.getParameterTypes());
        return ctor.newInstance(args);
      } catch (ReflectiveOperationException ignored) {
        // try next constructor
      }
    }
    throw new IllegalStateException("failed to instantiate type: " + type.getName());
  }

  private static Object[] defaultArgs(Class<?>[] parameterTypes) {
    if (parameterTypes == null || parameterTypes.length == 0) {
      return new Object[0];
    }
    Object[] out = new Object[parameterTypes.length];
    for (int i = 0; i < parameterTypes.length; i += 1) {
      out[i] = defaultValueFor(parameterTypes[i]);
    }
    return out;
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

  private static boolean attachLegacyStubProvider(Object instance, System.StubProvider provider) {
    if (instance == null || provider == null) {
      return false;
    }
    try {
      Method setter = instance.getClass().getMethod("__setStubProvider", System.StubProvider.class);
      setter.setAccessible(true);
      setter.invoke(instance, provider);
      return true;
    } catch (ReflectiveOperationException ignored) {
      return false;
    }
  }

  private static Object createInterfaceStub(Class<?> type, System.StubProvider provider) {
    InvocationHandler handler =
        (proxy, method, args) -> {
          if (method == null) {
            return null;
          }
          if (method.getDeclaringClass() == Object.class) {
            return handleObjectMethod(proxy, method, args);
          }
          Object[] safeArgs = args == null ? new Object[0] : args;
          String returnTypeName = apexTypeToken(method.getReturnType());
          String[] paramTypeNames = paramTypeTokens(method.getParameterTypes());
          Object result =
              __invokeStubbedMethod(
                  proxy,
                  method.getName(),
                  returnTypeName,
                  paramTypeNames,
                  safeArgs);
          if (method.getReturnType().isPrimitive()) {
            return coercePrimitiveResult(method.getReturnType(), result);
          }
          return result;
        };
    Object proxy =
        Proxy.newProxyInstance(
            type.getClassLoader(),
            new Class<?>[] {type},
            handler);
    STUB_PROVIDERS.get().put(proxy, provider);
    return proxy;
  }

  private static Object handleObjectMethod(Object proxy, Method method, Object[] args) {
    if (method == null) {
      return null;
    }
    String name = method.getName();
    if ("toString".equals(name)) {
      return "StubProxy(" + proxy.getClass().getInterfaces()[0].getSimpleName() + ")";
    }
    if ("hashCode".equals(name)) {
      return Integer.valueOf(java.lang.System.identityHashCode(proxy));
    }
    if ("equals".equals(name)) {
      Object other = (args == null || args.length == 0) ? null : args[0];
      return Boolean.valueOf(proxy == other);
    }
    return null;
  }

  private static Object instantiateDynamicSubclass(Class<?> targetType, System.StubProvider provider) {
    if (targetType == null || provider == null) {
      return null;
    }
    if (targetType.isPrimitive()
        || targetType.isArray()
        || targetType.isEnum()
        || Modifier.isFinal(targetType.getModifiers())) {
      return null;
    }

    Constructor<?> ctor = STUB_CONSTRUCTOR_CACHE.get().get(targetType);
    if (ctor == null) {
      ctor = compileDynamicStubConstructor(targetType);
      if (ctor != null) {
        STUB_CONSTRUCTOR_CACHE.get().put(targetType, ctor);
      }
    }
    if (ctor == null) {
      return null;
    }

    try {
      ctor.setAccessible(true);
      Object instance = ctor.newInstance();
      STUB_PROVIDERS.get().put(instance, provider);
      return instance;
    } catch (ReflectiveOperationException ignored) {
      return null;
    }
  }

  private static Constructor<?> compileDynamicStubConstructor(Class<?> targetType) {
    Constructor<?> superCtor = selectSuperConstructor(targetType);
    if (superCtor == null) {
      return null;
    }

    JavaCompiler compiler = ToolProvider.getSystemJavaCompiler();
    if (compiler == null) {
      return null;
    }

    String packageName = targetType.getPackageName();
    String targetName = qualifiedClassName(targetType);
    String stubSimpleName = targetType.getSimpleName() + "__sfdc_ApexStub";
    String stubClassName =
        (packageName == null || packageName.isBlank())
            ? stubSimpleName
            : packageName + "." + stubSimpleName;

    String source = buildStubSource(packageName, targetName, stubSimpleName, superCtor, targetType);

    Path workDir;
    Path sourceFile;
    try {
      workDir = Files.createTempDirectory("apexemu-stub-");
      if (packageName == null || packageName.isBlank()) {
        sourceFile = workDir.resolve(stubSimpleName + ".java");
      } else {
        Path packageDir = workDir.resolve(packageName.replace('.', '/'));
        Files.createDirectories(packageDir);
        sourceFile = packageDir.resolve(stubSimpleName + ".java");
      }
      Files.writeString(sourceFile, source, StandardCharsets.UTF_8);
    } catch (IOException error) {
      return null;
    }

    List<String> options = new ArrayList<>();
    options.add("-classpath");
    options.add(java.lang.System.getProperty("java.class.path", ""));
    options.add("-d");
    options.add(workDir.toString());

    try (StandardJavaFileManager fileManager =
        compiler.getStandardFileManager(null, null, StandardCharsets.UTF_8)) {
      Iterable<? extends javax.tools.JavaFileObject> units =
          fileManager.getJavaFileObjects(sourceFile.toFile());
      Boolean ok = compiler.getTask(null, fileManager, null, options, null, units).call();
      if (!Boolean.TRUE.equals(ok)) {
        return null;
      }
    } catch (IOException error) {
      return null;
    }

    try {
      URLClassLoader loader =
          new URLClassLoader(new URL[] {workDir.toUri().toURL()}, targetType.getClassLoader());
      Class<?> stubClass = Class.forName(stubClassName, true, loader);
      return stubClass.getDeclaredConstructor();
    } catch (ReflectiveOperationException | IOException error) {
      return null;
    }
  }

  private static Constructor<?> selectSuperConstructor(Class<?> targetType) {
    if (targetType == null) {
      return null;
    }

    try {
      Constructor<?> noArg = targetType.getDeclaredConstructor();
      if (!Modifier.isPrivate(noArg.getModifiers())) {
        return noArg;
      }
    } catch (NoSuchMethodException ignored) {
      // fall back
    }

    Constructor<?>[] constructors = targetType.getDeclaredConstructors();
    if (constructors == null || constructors.length == 0) {
      return null;
    }
    Arrays.sort(constructors, (left, right) -> Integer.compare(left.getParameterCount(), right.getParameterCount()));
    for (Constructor<?> ctor : constructors) {
      if (!Modifier.isPrivate(ctor.getModifiers())) {
        return ctor;
      }
    }
    return null;
  }

  private static String buildStubSource(
      String packageName,
      String targetClassName,
      String stubSimpleName,
      Constructor<?> superCtor,
      Class<?> targetType) {
    StringBuilder out = new StringBuilder();
    if (packageName != null && !packageName.isBlank()) {
      out.append("package ").append(packageName).append(";\n\n");
    }

    out.append("public class ").append(stubSimpleName).append(" extends ").append(targetClassName);
    appendImplementsClause(out, supportedNestedInterfaces(targetType));
    out.append(" {\n");
    out.append("  public ").append(stubSimpleName).append("()");
    appendThrowsClause(out, superCtor.getExceptionTypes());
    out.append(" {\n");
    out.append("    super(");
    appendDefaultSuperArgs(out, superCtor.getParameterTypes());
    out.append(");\n");
    out.append("  }\n");

    for (Method method : overridableMethods(targetType)) {
      out.append(renderOverrideMethod(method));
    }

    out.append("}\n");
    return out.toString();
  }

  private static List<Class<?>> supportedNestedInterfaces(Class<?> targetType) {
    List<Class<?>> out = new ArrayList<>();
    if (targetType == null) {
      return out;
    }
    for (Class<?> nested : targetType.getDeclaredClasses()) {
      if (nested == null || !nested.isInterface() || !Modifier.isPublic(nested.getModifiers())) {
        continue;
      }
      if (implementsAllInterfaceMethods(targetType, nested)) {
        out.add(nested);
      }
    }
    return out;
  }

  private static boolean implementsAllInterfaceMethods(Class<?> targetType, Class<?> nestedInterface) {
    if (targetType == null || nestedInterface == null || !nestedInterface.isInterface()) {
      return false;
    }
    for (Method interfaceMethod : nestedInterface.getMethods()) {
      if (interfaceMethod == null || interfaceMethod.getDeclaringClass() == Object.class) {
        continue;
      }
      try {
        Method targetMethod =
            targetType.getMethod(interfaceMethod.getName(), interfaceMethod.getParameterTypes());
        if (!interfaceMethod.getReturnType().isAssignableFrom(targetMethod.getReturnType())) {
          return false;
        }
      } catch (NoSuchMethodException ignored) {
        return false;
      }
    }
    return true;
  }

  private static void appendImplementsClause(StringBuilder out, List<Class<?>> interfaces) {
    if (out == null || interfaces == null || interfaces.isEmpty()) {
      return;
    }
    out.append(" implements ");
    for (int i = 0; i < interfaces.size(); i += 1) {
      if (i > 0) {
        out.append(", ");
      }
      out.append(typeSource(interfaces.get(i)));
    }
  }

  private static List<Method> overridableMethods(Class<?> targetType) {
    List<Method> out = new ArrayList<>();
    if (targetType == null) {
      return out;
    }
    for (Method method : targetType.getMethods()) {
      if (method == null) {
        continue;
      }
      if (method.getDeclaringClass() == Object.class) {
        continue;
      }
      int modifiers = method.getModifiers();
      if (Modifier.isStatic(modifiers)
          || Modifier.isFinal(modifiers)
          || Modifier.isPrivate(modifiers)
          || method.isSynthetic()
          || method.isBridge()) {
        continue;
      }
      if (!Modifier.isPublic(modifiers) && !Modifier.isProtected(modifiers)) {
        continue;
      }
      out.add(method);
    }
    return out;
  }

  private static String renderOverrideMethod(Method method) {
    StringBuilder out = new StringBuilder();
    Class<?> returnType = method.getReturnType();
    Class<?>[] parameterTypes = method.getParameterTypes();

    out.append("  @Override\n");
    out.append("  public ")
        .append(typeSource(returnType))
        .append(" ")
        .append(method.getName())
        .append("(");

    for (int i = 0; i < parameterTypes.length; i += 1) {
      if (i > 0) {
        out.append(", ");
      }
      out.append(typeSource(parameterTypes[i])).append(" p").append(i);
    }
    out.append(")");
    appendThrowsClause(out, method.getExceptionTypes());
    out.append(" {\n");

    String returnTypeToken = apexTypeToken(returnType);
    String[] paramTypeTokens = paramTypeTokens(parameterTypes);

    out.append("    java.lang.Object __result = apexemu.runtime.Test.__invokeStubbedMethod(")
        .append("this, ")
        .append(stringLiteral(method.getName()))
        .append(", ")
        .append(stringLiteral(returnTypeToken))
        .append(", new java.lang.String[] {");

    for (int i = 0; i < paramTypeTokens.length; i += 1) {
      if (i > 0) {
        out.append(", ");
      }
      out.append(stringLiteral(paramTypeTokens[i]));
    }
    out.append("}, new java.lang.Object[] {");
    for (int i = 0; i < parameterTypes.length; i += 1) {
      if (i > 0) {
        out.append(", ");
      }
      out.append("p").append(i);
    }
    out.append("});\n");

    if (returnType == void.class) {
      out.append("    return;\n");
    } else if (returnType.isPrimitive()) {
      out.append(renderPrimitiveReturn(returnType));
    } else {
      out.append("    return (").append(typeSource(returnType)).append(") __result;\n");
    }

    out.append("  }\n");
    return out.toString();
  }

  private static String renderPrimitiveReturn(Class<?> primitiveType) {
    StringBuilder out = new StringBuilder();
    if (primitiveType == boolean.class) {
      out.append("    if (__result == null) return false;\n")
          .append("    return ((java.lang.Boolean) __result).booleanValue();\n");
      return out.toString();
    }
    if (primitiveType == char.class) {
      out.append("    if (__result == null) return '\\0';\n")
          .append("    return ((java.lang.Character) __result).charValue();\n");
      return out.toString();
    }
    if (primitiveType == byte.class) {
      out.append("    if (__result == null) return (byte) 0;\n")
          .append("    return ((java.lang.Number) __result).byteValue();\n");
      return out.toString();
    }
    if (primitiveType == short.class) {
      out.append("    if (__result == null) return (short) 0;\n")
          .append("    return ((java.lang.Number) __result).shortValue();\n");
      return out.toString();
    }
    if (primitiveType == int.class) {
      out.append("    if (__result == null) return 0;\n")
          .append("    return ((java.lang.Number) __result).intValue();\n");
      return out.toString();
    }
    if (primitiveType == long.class) {
      out.append("    if (__result == null) return 0L;\n")
          .append("    return ((java.lang.Number) __result).longValue();\n");
      return out.toString();
    }
    if (primitiveType == float.class) {
      out.append("    if (__result == null) return 0F;\n")
          .append("    return ((java.lang.Number) __result).floatValue();\n");
      return out.toString();
    }
    if (primitiveType == double.class) {
      out.append("    if (__result == null) return 0D;\n")
          .append("    return ((java.lang.Number) __result).doubleValue();\n");
      return out.toString();
    }
    out.append("    return 0;\n");
    return out.toString();
  }

  private static Object coercePrimitiveResult(Class<?> primitiveType, Object value) {
    if (primitiveType == boolean.class) {
      return value == null ? Boolean.FALSE : Boolean.valueOf((Boolean) value);
    }
    if (primitiveType == char.class) {
      return value == null ? Character.valueOf('\0') : Character.valueOf((Character) value);
    }
    if (!(value instanceof Number number)) {
      if (primitiveType == byte.class) return Byte.valueOf((byte) 0);
      if (primitiveType == short.class) return Short.valueOf((short) 0);
      if (primitiveType == int.class) return Integer.valueOf(0);
      if (primitiveType == long.class) return Long.valueOf(0L);
      if (primitiveType == float.class) return Float.valueOf(0F);
      if (primitiveType == double.class) return Double.valueOf(0D);
      return Integer.valueOf(0);
    }
    if (primitiveType == byte.class) return Byte.valueOf(number.byteValue());
    if (primitiveType == short.class) return Short.valueOf(number.shortValue());
    if (primitiveType == int.class) return Integer.valueOf(number.intValue());
    if (primitiveType == long.class) return Long.valueOf(number.longValue());
    if (primitiveType == float.class) return Float.valueOf(number.floatValue());
    if (primitiveType == double.class) return Double.valueOf(number.doubleValue());
    return Integer.valueOf(0);
  }

  private static String typeSource(Class<?> type) {
    if (type == null) {
      return "java.lang.Object";
    }
    if (type.isArray()) {
      return typeSource(type.getComponentType()) + "[]";
    }
    if (type.isPrimitive()) {
      return type.getName();
    }
    String canonical = type.getCanonicalName();
    if (canonical != null && !canonical.isBlank()) {
      return canonical;
    }
    return type.getName().replace('$', '.');
  }

  private static String qualifiedClassName(Class<?> type) {
    if (type == null) {
      return "java.lang.Object";
    }
    String canonical = type.getCanonicalName();
    if (canonical != null && !canonical.isBlank()) {
      return canonical;
    }
    return type.getName().replace('$', '.');
  }

  private static void appendThrowsClause(StringBuilder out, Class<?>[] exceptionTypes) {
    if (exceptionTypes == null || exceptionTypes.length == 0) {
      return;
    }
    out.append(" throws ");
    for (int i = 0; i < exceptionTypes.length; i += 1) {
      if (i > 0) {
        out.append(", ");
      }
      out.append(typeSource(exceptionTypes[i]));
    }
  }

  private static void appendDefaultSuperArgs(StringBuilder out, Class<?>[] parameterTypes) {
    if (parameterTypes == null || parameterTypes.length == 0) {
      return;
    }
    for (int i = 0; i < parameterTypes.length; i += 1) {
      if (i > 0) {
        out.append(", ");
      }
      Class<?> parameterType = parameterTypes[i];
      if (parameterType == boolean.class) {
        out.append("false");
      } else if (parameterType == char.class) {
        out.append("'\\0'");
      } else if (parameterType == byte.class) {
        out.append("(byte) 0");
      } else if (parameterType == short.class) {
        out.append("(short) 0");
      } else if (parameterType == int.class) {
        out.append("0");
      } else if (parameterType == long.class) {
        out.append("0L");
      } else if (parameterType == float.class) {
        out.append("0F");
      } else if (parameterType == double.class) {
        out.append("0D");
      } else {
        out.append("null");
      }
    }
  }

  private static String stringLiteral(String value) {
    if (value == null) {
      return "null";
    }
    return "\""
        + value
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t")
        + "\"";
  }

  private static String apexTypeToken(Class<?> type) {
    if (type == null || type == void.class || type == Void.class) {
      return null;
    }
    if (type == String.class) {
      return "String";
    }
    if (type == Boolean.class || type == boolean.class) {
      return "Boolean";
    }
    if (type == Integer.class || type == int.class || type == Short.class || type == short.class) {
      return "Integer";
    }
    if (type == Long.class || type == long.class) {
      return "Long";
    }
    if (type == Double.class || type == double.class || type == Float.class || type == float.class) {
      return "Double";
    }
    String simple = type.getSimpleName();
    if (simple == null || simple.isBlank()) {
      simple = type.getName();
    }
    return simple.replace('$', '.');
  }

  private static String[] paramTypeTokens(Class<?>[] parameterTypes) {
    if (parameterTypes == null || parameterTypes.length == 0) {
      return new String[0];
    }
    String[] out = new String[parameterTypes.length];
    for (int i = 0; i < parameterTypes.length; i += 1) {
      out[i] = apexTypeToken(parameterTypes[i]);
    }
    return out;
  }

  public static Object __invokeStubbedMethod(
      Object stubbedObject,
      String methodName,
      String returnTypeName,
      String[] paramTypeNames,
      Object[] args) {
    if (stubbedObject == null) {
      return null;
    }
    System.StubProvider provider = STUB_PROVIDERS.get().get(stubbedObject);
    if (provider == null) {
      return null;
    }

    System.Type returnType = toTypeToken(returnTypeName);
    List<System.Type> paramTypes = new ArrayList<>();
    List<String> paramNames = new ArrayList<>();
    List<Object> argList = new ArrayList<>();

    if (paramTypeNames != null) {
      for (int i = 0; i < paramTypeNames.length; i += 1) {
        paramTypes.add(toTypeToken(paramTypeNames[i]));
        paramNames.add("arg" + i);
      }
    }

    if (args != null) {
      argList.addAll(Arrays.asList(args));
      for (int i = paramNames.size(); i < args.length; i += 1) {
        paramNames.add("arg" + i);
      }
    }

    return invokeStubProvider(provider, stubbedObject, methodName, returnType, paramTypes, paramNames, argList);
  }

  private static System.Type toTypeToken(String name) {
    if (name == null || name.isBlank()) {
      return null;
    }
    try {
      return System.Type.forName(name);
    } catch (RuntimeException ignored) {
      return null;
    }
  }

  private static Object invokeStubProvider(
      System.StubProvider provider,
      Object stubbedObject,
      String methodName,
      System.Type returnType,
      List<System.Type> paramTypes,
      List<String> paramNames,
      List<Object> args) {
    if (provider == null) {
      return null;
    }

    Object testDoubleResult =
        tryInvokeGeneratedTestDouble(provider, methodName, paramTypes, args);
    if (testDoubleResult != NO_STUB_MATCH) {
      return testDoubleResult;
    }

    List<System.Type> safeParamTypes = paramTypes == null ? List.of() : paramTypes;
    List<String> safeParamNames = paramNames == null ? List.of() : paramNames;
    List<Object> safeArgs = args == null ? List.of() : args;

    return provider.handleMethodCall(
        stubbedObject,
        methodName == null ? "" : methodName,
        returnType,
        safeParamTypes,
        safeParamNames,
        safeArgs);
  }

  private static Object tryInvokeGeneratedTestDouble(
      System.StubProvider provider,
      String stubbedMethodName,
      List<System.Type> listOfParamTypes,
      List<Object> listOfArgs) {
    if (provider == null) {
      return NO_STUB_MATCH;
    }

    String providerSimpleName = provider.getClass().getSimpleName();
    if (providerSimpleName == null || !providerSimpleName.equalsIgnoreCase("TestDouble")) {
      return NO_STUB_MATCH;
    }

    Object methodsObj = readField(provider, "methods");
    if (!(methodsObj instanceof List<?> methods)) {
      return NO_STUB_MATCH;
    }

    for (Object methodDef : methods) {
      if (methodDef == null) {
        continue;
      }
      String name = stringValue(readField(methodDef, "name"));
      if (name == null || !name.equalsIgnoreCase(stubbedMethodName == null ? "" : stubbedMethodName)) {
        continue;
      }

      List<?> expectedParamTypes = asList(readField(methodDef, "listOfParamTypes"));
      List<?> expectedArgs = asList(readField(methodDef, "listOfArgs"));

      if (!expectedParamTypes.isEmpty()
          && !matchesParamTypes(expectedParamTypes, listOfParamTypes == null ? List.of() : listOfParamTypes)) {
        continue;
      }
      if (!expectedArgs.isEmpty()
          && !matchesArgs(expectedArgs, listOfArgs == null ? List.of() : listOfArgs)) {
        continue;
      }

      try {
        Method handleCall = methodDef.getClass().getMethod("handleCall");
        handleCall.setAccessible(true);
        return handleCall.invoke(methodDef);
      } catch (InvocationTargetException error) {
        Throwable cause = error.getCause();
        if (cause instanceof RuntimeException runtimeError) {
          throw runtimeError;
        }
        if (cause instanceof Error severeError) {
          throw severeError;
        }
        throw new IllegalStateException("stub provider method threw checked exception", cause);
      } catch (ReflectiveOperationException error) {
        throw new IllegalStateException("failed to invoke generated TestDouble", error);
      }
    }

    return NO_STUB_MATCH;
  }

  private static List<?> asList(Object value) {
    if (value instanceof List<?> list) {
      return list;
    }
    return List.of();
  }

  private static boolean matchesParamTypes(List<?> expected, List<System.Type> actual) {
    if (expected == null || expected.isEmpty()) {
      return true;
    }
    if (actual == null || expected.size() != actual.size()) {
      return false;
    }
    for (int i = 0; i < expected.size(); i += 1) {
      String left = normalizeTypeName(expected.get(i));
      String right = normalizeTypeName(actual.get(i));
      if (!Objects.equals(left, right)) {
        return false;
      }
    }
    return true;
  }

  private static String normalizeTypeName(Object value) {
    if (value == null) {
      return null;
    }
    if (value instanceof System.Type type) {
      String name = type.getName();
      return name == null ? null : name.trim().toLowerCase(Locale.ROOT);
    }
    return String.valueOf(value).trim().toLowerCase(Locale.ROOT);
  }

  private static boolean matchesArgs(List<?> expected, List<Object> actual) {
    if (expected == null || expected.isEmpty()) {
      return true;
    }
    if (actual == null || expected.size() != actual.size()) {
      return false;
    }
    for (int i = 0; i < expected.size(); i += 1) {
      Object left = expected.get(i);
      Object right = actual.get(i);
      if (!Objects.equals(left, right)) {
        return false;
      }
    }
    return true;
  }

  private static Object readField(Object receiver, String fieldName) {
    if (receiver == null || fieldName == null || fieldName.isBlank()) {
      return null;
    }
    Class<?> cursor = receiver.getClass();
    while (cursor != null && cursor != Object.class) {
      try {
        java.lang.reflect.Field field = cursor.getDeclaredField(fieldName);
        field.setAccessible(true);
        return field.get(receiver);
      } catch (NoSuchFieldException ignored) {
        cursor = cursor.getSuperclass();
      } catch (IllegalAccessException ignored) {
        return null;
      }
    }
    return null;
  }

  private static String stringValue(Object value) {
    if (value == null) {
      return null;
    }
    return String.valueOf(value);
  }

  public static void calculatePermissionSetGroup(Object permissionSetGroupId) {
    // No-op in local emulation.
  }

  public static EventBusController getEventBus() {
    return EVENT_BUS.get();
  }

  private static final class DelegatingStubProvider implements System.StubProvider {
    private final System.StubProvider delegate;

    private DelegatingStubProvider(System.StubProvider delegate) {
      this.delegate = delegate;
    }

    @Override
    public Object handleMethodCall(
        Object stubbedObject,
        String methodName,
        System.Type returnType,
        List<System.Type> paramTypes,
        List<String> paramNames,
        List<Object> args) {
      return invokeStubProvider(delegate, stubbedObject, methodName, returnType, paramTypes, paramNames, args);
    }
  }

  public static final class EventBusController {
    public void deliver() {
      EventBus.forceDelivery();
    }

    public void fail() {
      EventBus.forceFailure();
    }
  }
}
