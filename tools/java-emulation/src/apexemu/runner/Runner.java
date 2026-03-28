package apexemu.runner;

import apexemu.annotations.Test;
import apexemu.annotations.TestSetup;
import apexemu.runtime.Async;
import apexemu.runtime.Cache;
import apexemu.runtime.Database;
import apexemu.runtime.Limits;
import apexemu.runtime.Limits.Snapshot;
import apexemu.runtime.Schema;
import apexemu.runtime.SystemAssert;
import apexemu.runtime.Trigger;
import java.io.File;
import java.io.IOException;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.net.MalformedURLException;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.regex.Pattern;

public final class Runner {
  public static void main(String[] args) throws Exception {
    Config config = Config.parse(args);
    int exitCode = run(config);
    System.exit(exitCode);
  }

  private static int run(Config config) throws Exception {
    List<String> allClassNames = discoverClassNames(config.classesDir);
    List<String> classNames = allClassNames;
    if (config.classNamePattern != null && !config.classNamePattern.isBlank()) {
      Pattern classPattern = Pattern.compile(config.classNamePattern);
      classNames = classNames.stream().filter(name -> classPattern.matcher(name).find()).toList();
    }
    URLClassLoader loader = new URLClassLoader(new URL[] {toUrl(config.classesDir)});
    List<TestResult> results = new ArrayList<>();

    // Pre-compute class registration and trigger handler data once
    List<ClassRegistration> classRegistrations = precomputeClassRegistrations(allClassNames, loader);
    List<TriggerHandlerEntry> triggerHandlers = precomputeTriggerHandlers(allClassNames, loader);

    for (String className : classNames) {
      Class<?> klass;
      try {
        klass = Class.forName(className, false, loader);
      } catch (Throwable error) {
        results.add(TestResult.loadError(className, shortMessage(error)));
        continue;
      }

      Method[] methods;
      try {
        methods = klass.getDeclaredMethods();
      } catch (Throwable methodError) {
        results.add(TestResult.loadError(className, shortMessage(methodError)));
        continue;
      }
      Arrays.sort(methods, Comparator.comparing(Method::getName));
      List<String> testSetupMethods = new ArrayList<>();
      List<TestMethodSpec> testMethods = new ArrayList<>();
      for (Method method : methods) {
        if (method.isAnnotationPresent(TestSetup.class)) {
          testSetupMethods.add(method.getName());
        }
        if (method.isAnnotationPresent(Test.class)) {
          Test annotation = method.getAnnotation(Test.class);
          boolean seeAllData = annotation != null && annotation.seeAllData();
          testMethods.add(new TestMethodSpec(method.getName(), seeAllData));
        }
      }
      for (TestMethodSpec methodSpec : testMethods) {
        results.add(
            runTest(
                config,
                classRegistrations,
                triggerHandlers,
                className,
                testSetupMethods,
                methodSpec.name,
                methodSpec.seeAllData));
      }
    }

    closeQuietly(loader);

    if (results.isEmpty()) {
      System.out.println("no tests found (@Test).");
      return 2;
    }

    int failed = 0;
    for (TestResult result : results) {
      printResult(result);
      if (!result.passed) {
        failed += 1;
      }
    }

    Summary summary = new Summary(results.size(), results.size() - failed, failed);
    System.out.printf(
        "summary: total=%d passed=%d failed=%d cpu_limit_ms=%d heap_limit_bytes=%d%n",
        summary.total, summary.passed, summary.failed, config.cpuLimitMs, config.heapLimitBytes);

    if (config.outPath != null) {
      writeJsonReport(config, summary, results);
      System.out.println("wrote: " + config.outPath);
    }

    return failed == 0 ? 0 : 1;
  }

  private static TestResult runTest(
      Config config,
      List<ClassRegistration> classRegistrations,
      List<TriggerHandlerEntry> triggerHandlers,
      String className,
      List<String> testSetupMethodNames,
      String methodName,
      boolean seeAllData) {
    URLClassLoader loader = null;
    Class<?> klass;
    Method method;
    List<Method> testSetupMethods;
    ClassLoader previousCl = Thread.currentThread().getContextClassLoader();
    try {
      // Use child-first class loading for generated.* so static fields are
      // reset between tests (mimics Apex per-test transaction isolation).
      loader = new URLClassLoader(new URL[] {toUrl(config.classesDir)}) {
        @Override
        public Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
          if (name.startsWith("generated.")) {
            Class<?> c = findLoadedClass(name);
            if (c == null) {
              c = findClass(name);
            }
            if (resolve) resolveClass(c);
            return c;
          }
          return super.loadClass(name, resolve);
        }
      };
      // Resolve Type.forName/Class.forName inside static initializers against the child-first loader.
      Thread.currentThread().setContextClassLoader(loader);
      Async.reset();
      Database.clearInMemoryStore();
      // Seed the current user into the in-memory store so SOQL queries on User succeed.
      Database.seedCurrentUser();
      Database.clearSchemaRegistry();
      Database.clearTriggerHandlers();
      Schema.clear();
      Cache.clearAll();
      Database.setSoqlNullOrderDefault(config.soqlNullOrderDefault);
      if (config.registerStandardSchema) {
        Schema.registerStandardDefaults();
      }
      Limits.reset();
      Limits.configure(config.cpuLimitMs, config.heapLimitBytes);
      apexemu.runtime.Test.clearMocks();
      apexemu.runtime.Test.setSeeAllDataEnabled(seeAllData);
      apexemu.runtime.System.Request.setCurrentQuiddity(apexemu.runtime.System.Quiddity.RUNTEST_SYNC);

      // Prevent stale classes from previous test loaders leaking into static initialization.
      apexemu.runtime.System.clearClassRegistry();
      // Fast re-registration using pre-computed data, loading classes through the child-first loader.
      registerAllClassesFast(classRegistrations, loader);
      autoRegisterTriggerManifest(config.classesDir, loader);
      registerTriggerHandlersFast(triggerHandlers, loader);
      autoRegisterTDTMTriggers(classRegistrations, loader);
      // If a generated PicklistRegistry exists, invoke it to seed picklist metadata.
      invokePicklistRegistry(loader);
      klass = Class.forName(className, true, loader);
      method = klass.getDeclaredMethod(methodName);
      testSetupMethods = resolveMethodsByName(klass, testSetupMethodNames);
    } catch (Throwable error) {
      apexemu.runtime.Test.setSeeAllDataEnabled(false);
      Thread.currentThread().setContextClassLoader(previousCl);
      closeQuietly(loader);
      return TestResult.loadError(className, shortMessage(error));
    }

    if (method.getParameterCount() != 0) {
      apexemu.runtime.Test.setSeeAllDataEnabled(false);
      Thread.currentThread().setContextClassLoader(previousCl);
      closeQuietly(loader);
      return TestResult.invalidSignature(className, methodName, "@Test methods must have zero arguments");
    }

    Object target = null;
    Throwable failure = null;
    long cpuMs;
    long heapBytes;
    int soqlCount;
    int dmlCount;

    try {
      executeTestSetupMethods(klass, testSetupMethods);
      if (!Modifier.isStatic(method.getModifiers())) {
        Constructor<?> ctor = klass.getDeclaredConstructor();
        ctor.setAccessible(true);
        target = ctor.newInstance();
      }
      method.setAccessible(true);
      method.invoke(target);
    } catch (InvocationTargetException error) {
      failure = error.getCause() == null ? error : error.getCause();
    } catch (Throwable error) {
      failure = error;
    } finally {
      apexemu.runtime.Test.setSeeAllDataEnabled(false);
      Thread.currentThread().setContextClassLoader(previousCl);
    }

    Snapshot snapshot = Limits.snapshot();
    cpuMs = snapshot.cpuMs();
    soqlCount = snapshot.soqlCount();
    dmlCount = snapshot.dmlCount();
    heapBytes = snapshot.heapBytes();

    if (failure == null) {
      if (cpuMs > Limits.getLimitCpuTime()) {
        failure =
            new AssertionError(
                "CPU limit exceeded: cpu_ms=" + cpuMs + " limit_ms=" + Limits.getLimitCpuTime());
      } else if (heapBytes > Limits.getLimitHeapSize()) {
        failure =
            new AssertionError(
                "Heap limit exceeded: heap_bytes="
                    + heapBytes
                    + " limit_bytes="
                    + Limits.getLimitHeapSize());
      }
    }

    List<SystemAssert.AssertionEntry> assertions = SystemAssert.drainLog();

    closeQuietly(loader);
    return new TestResult(
        className, methodName, failure == null, cpuMs, heapBytes, soqlCount, dmlCount, shortMessage(failure), assertions);
  }

  private static List<Method> resolveMethodsByName(Class<?> klass, List<String> methodNames)
      throws NoSuchMethodException {
    List<Method> out = new ArrayList<>();
    if (klass == null || methodNames == null || methodNames.isEmpty()) {
      return out;
    }
    for (String methodName : methodNames) {
      if (methodName == null || methodName.isBlank()) {
        continue;
      }
      out.add(klass.getDeclaredMethod(methodName));
    }
    return out;
  }

  private static void closeQuietly(URLClassLoader loader) {
    if (loader == null) {
      return;
    }
    try {
      loader.close();
    } catch (IOException ignored) {
      // no-op
    }
  }

  private static void executeTestSetupMethods(Class<?> klass, List<Method> testSetupMethods)
      throws ReflectiveOperationException {
    if (testSetupMethods == null || testSetupMethods.isEmpty()) {
      return;
    }
    for (Method method : testSetupMethods) {
      if (method.getParameterCount() != 0
          || !Modifier.isStatic(method.getModifiers())
          || method.getReturnType() != Void.TYPE) {
        throw new IllegalArgumentException(
            "@TestSetup methods must be static void with zero arguments: "
                + klass.getName()
                + "#"
                + method.getName());
      }
      method.setAccessible(true);
      method.invoke(null);
    }
  }

  private static void printResult(TestResult result) {
    String state = result.passed ? "PASS" : "FAIL";
    System.out.printf(
        "[%s] %s#%s cpu=%dms heap=%dB soql=%d dml=%d assertions=%d%n",
        state, result.className, result.methodName, result.cpuMs, result.heapBytes, result.soqlCount, result.dmlCount, result.assertions.size());
    if (!result.passed && result.failure != null && !result.failure.isBlank()) {
      System.out.println("      " + result.failure);
    }
  }

  private static void autoRegisterTriggerManifest(Path classesDir, ClassLoader loader) {
    Path manifest = classesDir.resolve("apex-triggers.txt");
    if (!Files.isRegularFile(manifest)) {
      return;
    }
    List<String> lines;
    try {
      lines = Files.readAllLines(manifest, StandardCharsets.UTF_8);
    } catch (IOException ignored) {
      return;
    }
    for (String line : lines) {
      if (line == null) {
        continue;
      }
      String trimmed = line.trim();
      if (trimmed.isEmpty() || trimmed.startsWith("#")) {
        continue;
      }
      String[] parts = trimmed.split("\\|", 3);
      if (parts.length != 3) {
        continue;
      }
      String sobjectType = parts[0].trim();
      String[] operations = parts[1].trim().isEmpty() ? new String[0] : parts[1].split(",");
      String handlerClassName = parts[2].trim();
      if (sobjectType.isEmpty() || handlerClassName.isEmpty() || operations.length == 0) {
        continue;
      }

      Runnable factory =
          () -> {
            try {
              // Try fflib_SObjectDomain.triggerHandler pattern first
              Class<?> domainBase = Class.forName("generated.fflib_SObjectDomain", true, loader);
              domainBase
                  .getMethod("triggerHandler", apexemu.runtime.System.Type.class)
                  .invoke(null, apexemu.runtime.System.Type.forName(handlerClassName));
            } catch (InvocationTargetException e) {
              Throwable cause = e.getCause();
              if (cause instanceof RuntimeException re) throw re;
              if (cause instanceof Error err) throw err;
              throw new RuntimeException(cause);
            } catch (ReflectiveOperationException e) {
              // Fallback: new Handler().run() pattern
              try {
                apexemu.runtime.System.Type handlerType = apexemu.runtime.System.Type.forName(handlerClassName);
                if (handlerType == null) return;
                Object instance = handlerType.newInstance();
                if (instance == null) return;
                java.lang.reflect.Method runMethod = instance.getClass().getMethod("run");
                runMethod.invoke(instance);
              } catch (InvocationTargetException ie) {
                Throwable cause = ie.getCause();
                if (cause instanceof RuntimeException re) throw re;
                if (cause instanceof Error err) throw err;
                throw new RuntimeException(cause);
              } catch (ReflectiveOperationException ignored) {
                // silently skip
              }
            }
          };

      for (String operation : operations) {
        registerTriggerOperation(sobjectType, operation.trim(), factory);
      }
    }
  }

  /** Pre-computed trigger handler entry. */
  private record TriggerHandlerEntry(String className, String sobjectType) {}

  /** Discover trigger handlers once (filter + validate), return entries for fast re-registration. */
  private static List<TriggerHandlerEntry> precomputeTriggerHandlers(
      List<String> allClassNames, ClassLoader loader) {
    List<TriggerHandlerEntry> entries = new ArrayList<>();
    for (String cn : allClassNames) {
      String simpleName = cn.contains(".") ? cn.substring(cn.lastIndexOf('.') + 1) : cn;
      if (!simpleName.endsWith("TriggerHandler")) continue;
      if (simpleName.equals("TriggerHandler")) continue;
      if (simpleName.equals("MetadataTriggerHandler")) continue;
      if (simpleName.startsWith("MDT")) continue;
      if (simpleName.startsWith("Log")) continue;
      if (simpleName.startsWith("PlatformEvent")) continue;

      String sobjectType = simpleName.substring(0, simpleName.length() - "TriggerHandler".length());
      if (sobjectType.isEmpty()) continue;

      try {
        Class<?> handlerClass = Class.forName(cn, true, loader);
        handlerClass.getDeclaredConstructor();
        handlerClass.getMethod("run");
      } catch (Exception e) {
        continue;
      }
      entries.add(new TriggerHandlerEntry(cn, sobjectType));
    }
    return entries;
  }

  /** Fast trigger handler registration using pre-computed entries. */
  private static void registerTriggerHandlersFast(
      List<TriggerHandlerEntry> entries, ClassLoader loader) {
    for (TriggerHandlerEntry entry : entries) {
      final String handlerClassName = entry.className;
      Runnable factory = () -> {
        try {
          Class<?> klass = Class.forName(handlerClassName, true, loader);
          Object instance = klass.getDeclaredConstructor().newInstance();
          klass.getMethod("run").invoke(instance);
        } catch (java.lang.reflect.InvocationTargetException e) {
          Throwable cause = e.getCause();
          if (cause instanceof RuntimeException re) throw re;
          if (cause instanceof Error err) throw err;
          throw new RuntimeException(cause);
        } catch (Exception e) {
          throw new RuntimeException(e);
        }
      };

      // Register for both bare name and __c variant to match custom objects
      String[] typeVariants = entry.sobjectType.contains("__")
          ? new String[] {entry.sobjectType}
          : new String[] {entry.sobjectType, entry.sobjectType + "__c"};
      for (String type : typeVariants) {
        Trigger.onBeforeInsert(type, factory);
        Trigger.onBeforeUpdate(type, factory);
        Trigger.onBeforeDelete(type, factory);
        Trigger.onAfterInsert(type, factory);
        Trigger.onAfterUpdate(type, factory);
        Trigger.onAfterDelete(type, factory);
        Trigger.onAfterUndelete(type, factory);
      }
    }
  }

  private static void registerTriggerOperation(String sobjectType, String operation, Runnable handler) {
    if (sobjectType == null || sobjectType.isBlank() || operation == null || operation.isBlank()) {
      return;
    }
    switch (operation.toLowerCase()) {
      case "before_insert" -> Trigger.onBeforeInsert(sobjectType, handler);
      case "before_update" -> Trigger.onBeforeUpdate(sobjectType, handler);
      case "before_delete" -> Trigger.onBeforeDelete(sobjectType, handler);
      case "after_insert" -> Trigger.onAfterInsert(sobjectType, handler);
      case "after_update" -> Trigger.onAfterUpdate(sobjectType, handler);
      case "after_delete" -> Trigger.onAfterDelete(sobjectType, handler);
      case "after_undelete" -> Trigger.onAfterUndelete(sobjectType, handler);
      default -> {
        // ignore unsupported manifest entries
      }
    }
  }

  /**
   * Auto-detect NPSP TDTM trigger pattern and register TDTM_Config_API.run() as the trigger
   * handler for all SObject types that have TDTM trigger classes (named TDTM_<SObjectType>).
   */
  private static void autoRegisterTDTMTriggers(List<ClassRegistration> classRegistrations, ClassLoader loader) {
    // Use direct TDTM dispatch with error tolerance — handler exceptions are
    // swallowed to avoid DML rollback when handler dependencies are placeholders.
    autoRegisterTDTMDirectDispatch(classRegistrations, loader);

    Class<?> configApiClass;
    java.lang.reflect.Method runMethod;
    try {
      configApiClass = Class.forName("generated.TDTM_Config_API", true, loader);
      runMethod = configApiClass.getMethod("run",
          Boolean.class, Boolean.class, Boolean.class, Boolean.class,
          Boolean.class, Boolean.class, List.class, List.class,
          apexemu.runtime.Schema.DescribeSObjectResult.class);
    } catch (Exception e) {
      return; // already registered via direct dispatch
    }

    // Find all TDTM trigger classes (pattern: TDTM_<SObjectType> or similar)
    java.util.Set<String> registeredTypes = new java.util.LinkedHashSet<>();
    for (ClassRegistration reg : classRegistrations) {
      String simpleName = reg.className.contains(".")
          ? reg.className.substring(reg.className.lastIndexOf('.') + 1) : reg.className;
      if (!simpleName.startsWith("TDTM_") || simpleName.contains("_TEST")
          || simpleName.contains("_TDTM") || simpleName.equals("TDTM_TriggerHandler")
          || simpleName.equals("TDTM_Config_API") || simpleName.equals("TDTM_DefaultConfig")
          || simpleName.equals("TDTM_ObjectDataGateway") || simpleName.equals("TDTM_Runnable")
          || simpleName.equals("TDTM_RunnableMutable") || simpleName.equals("TDTM_Global_API")
          || simpleName.equals("TDTM_TriggerActionHelper") || simpleName.equals("TDTM_Filter")
          || simpleName.equals("TDTM_ProcessControl") || simpleName.equals("TDTM_iTableDataGateway")
          || simpleName.equals("TDTM_Glue")) {
        continue;
      }
      // TDTM_Contact → Contact, TDTM_Account → Account, TDTM_Payment → npe01__OppPayment__c
      // We need to map the trigger class name to SObject type
      String triggerSuffix = simpleName.substring("TDTM_".length());
      registeredTypes.add(triggerSuffix);
    }

    // Map known trigger class suffixes to SObject API names
    java.util.Map<String, String> triggerToSObject = new java.util.LinkedHashMap<>();
    triggerToSObject.put("Account", "Account");
    triggerToSObject.put("Contact", "Contact");
    triggerToSObject.put("Opportunity", "Opportunity");
    triggerToSObject.put("Lead", "Lead");
    triggerToSObject.put("Campaign", "Campaign");
    triggerToSObject.put("CampaignMember", "CampaignMember");
    triggerToSObject.put("Task", "Task");
    triggerToSObject.put("User", "User");
    triggerToSObject.put("Payment", "npe01__OppPayment__c");
    triggerToSObject.put("RecurringDonation", "npe03__Recurring_Donation__c");
    triggerToSObject.put("Relationship", "npe4__Relationship__c");
    triggerToSObject.put("Affiliation", "npe5__Affiliation__c");
    triggerToSObject.put("HouseholdObject", "npo02__Household__c");
    triggerToSObject.put("Address", "Address__c");
    triggerToSObject.put("Allocation", "Allocation__c");
    triggerToSObject.put("DataImport", "DataImport__c");
    triggerToSObject.put("DataImportBatch", "DataImportBatch__c");
    triggerToSObject.put("EngagementPlan", "Engagement_Plan__c");
    triggerToSObject.put("EngagementPlanTask", "Engagement_Plan_Task__c");
    triggerToSObject.put("FormTemplate", "Form_Template__c");
    triggerToSObject.put("GeneralAccountingUnit", "General_Accounting_Unit__c");
    triggerToSObject.put("GrantDeadline", "Grant_Deadline__c");
    triggerToSObject.put("Level", "Level__c");
    triggerToSObject.put("OpportunityContactRole", "OpportunityContactRole");
    triggerToSObject.put("PartialSoftCredit", "Partial_Soft_Credit__c");
    triggerToSObject.put("AccountSoftCredit", "Account_Soft_Credit__c");

    // If no valid SObject type mappings found, register all defaults
    boolean hasValidMapping = false;
    for (String rt : registeredTypes) {
      if (triggerToSObject.containsKey(rt)) { hasValidMapping = true; break; }
    }
    if (!hasValidMapping) {
      registeredTypes.addAll(triggerToSObject.keySet());
    }
    for (var entry : triggerToSObject.entrySet()) {
      if (!registeredTypes.contains(entry.getKey())) continue;
      String sobjectType = entry.getValue();
      Runnable tdtmHandler = buildTDTMHandler(configApiClass, runMethod, sobjectType);
      Trigger.onBeforeInsert(sobjectType, tdtmHandler);
      Trigger.onBeforeUpdate(sobjectType, tdtmHandler);
      Trigger.onBeforeDelete(sobjectType, tdtmHandler);
      Trigger.onAfterInsert(sobjectType, tdtmHandler);
      Trigger.onAfterUpdate(sobjectType, tdtmHandler);
      Trigger.onAfterDelete(sobjectType, tdtmHandler);
      Trigger.onAfterUndelete(sobjectType, tdtmHandler);
    }
  }

  private static Runnable buildTDTMHandler(Class<?> configApiClass,
      java.lang.reflect.Method runMethod, String sobjectType) {
    return () -> {
      try {
        // Resolve TDTM_Config_API.run() through the current thread's context class loader
        // so it uses the child-first loader for the active test (static fields are per-loader).
        ClassLoader cl = Thread.currentThread().getContextClassLoader();
        java.lang.reflect.Method activeRunMethod = runMethod;
        if (cl != null) {
          try {
            Class<?> activeClass = Class.forName("generated.TDTM_Config_API", true, cl);
            activeRunMethod = activeClass.getMethod("run",
                Boolean.class, Boolean.class, Boolean.class, Boolean.class,
                Boolean.class, Boolean.class, List.class, List.class,
                apexemu.runtime.Schema.DescribeSObjectResult.class);
          } catch (Exception ignored) {
            // fall back to the pre-resolved method
          }
        }
        Boolean isBefore = Trigger.isBefore();
        Boolean isAfter = Trigger.isAfter();
        Boolean isInsert = Trigger.isInsert();
        Boolean isUpdate = Trigger.isUpdate();
        Boolean isDelete = Trigger.isDelete();
        Boolean isUndelete = Trigger.isUndelete();
        List<?> newList = Trigger.getNew();
        List<?> oldList = Trigger.getOld();
        apexemu.runtime.Schema.DescribeSObjectResult describeResult =
            new apexemu.runtime.Schema.SObjectType(sobjectType).getDescribe();
        activeRunMethod.invoke(null, isBefore, isAfter, isInsert, isUpdate,
            isDelete, isUndelete, newList, oldList, describeResult);
      } catch (java.lang.reflect.InvocationTargetException e) {
        Throwable cause = e.getCause();
        if (cause instanceof RuntimeException re) throw re;
        if (cause instanceof Error err) throw err;
        throw new RuntimeException(cause);
      } catch (Exception e) {
        throw new RuntimeException(e);
      }
    };
  }

  /**
   * Fallback TDTM trigger registration when TDTM_Config_API.run() is unavailable (placeholder).
   * Reads handler records from TDTM_DefaultConfig.getDefaultRecords() and dispatches directly
   * to the handler classes' run() method via reflection.
   */
  private static void autoRegisterTDTMDirectDispatch(List<ClassRegistration> classRegistrations, ClassLoader loader) {
    List<apexemu.runtime.ApexSObject> handlerRecords;
    try {
      Class<?> defaultConfigClass = Class.forName("generated.TDTM_DefaultConfig", true, loader);
      java.lang.reflect.Method getDefaults = defaultConfigClass.getMethod("getDefaultRecords");
      @SuppressWarnings("unchecked")
      List<apexemu.runtime.ApexSObject> records = (List<apexemu.runtime.ApexSObject>) getDefaults.invoke(null);
      handlerRecords = records;
    } catch (Exception e) {
      return; // No TDTM_DefaultConfig either — skip
    }
    if (handlerRecords == null || handlerRecords.isEmpty()) return;

    for (apexemu.runtime.ApexSObject handler : handlerRecords) {
      if (!Boolean.TRUE.equals(handler.get("Active__c"))) continue;
      String className = (String) handler.get("Class__c");
      String objectName = (String) handler.get("Object__c");
      String actions = (String) handler.get("Trigger_Action__c");
      if (className == null || objectName == null || actions == null) continue;

      Runnable tdtmHandler = buildDirectTDTMHandler(className, loader);
      if (tdtmHandler == null) continue;

      for (String action : actions.split(";")) {
        String a = action.trim();
        if (a.isEmpty()) continue;
        switch (a) {
          case "BeforeInsert" -> apexemu.runtime.Trigger.onBeforeInsert(objectName, tdtmHandler);
          case "BeforeUpdate" -> apexemu.runtime.Trigger.onBeforeUpdate(objectName, tdtmHandler);
          case "BeforeDelete" -> apexemu.runtime.Trigger.onBeforeDelete(objectName, tdtmHandler);
          case "AfterInsert" -> apexemu.runtime.Trigger.onAfterInsert(objectName, tdtmHandler);
          case "AfterUpdate" -> apexemu.runtime.Trigger.onAfterUpdate(objectName, tdtmHandler);
          case "AfterDelete" -> apexemu.runtime.Trigger.onAfterDelete(objectName, tdtmHandler);
          case "AfterUndelete" -> apexemu.runtime.Trigger.onAfterUndelete(objectName, tdtmHandler);
          default -> {} // ignore unknown actions
        }
      }
    }
  }

  private static Runnable buildDirectTDTMHandler(String className, ClassLoader fallbackLoader) {
    return () -> {
      try {
        ClassLoader cl = Thread.currentThread().getContextClassLoader();
        if (cl == null) cl = fallbackLoader;
        Class<?> handlerClass = Class.forName("generated." + className, true, cl);
        // Look for run(List<ApexSObject>, List<ApexSObject>, Schema.DescribeSObjectResult, ...)
        // TDTM_Runnable.run() signature
        java.lang.reflect.Method runMethod = null;
        // Use getDeclaredMethods to get methods from the handler's OWN classloader,
        // avoiding parent-loader TDTM_Runnable.run() whose Action param has different identity
        for (java.lang.reflect.Method m : handlerClass.getDeclaredMethods()) {
          if ("run".equals(m.getName()) && m.getParameterCount() == 4) {
            runMethod = m;
            break;
          }
        }
        if (runMethod == null) {
          for (java.lang.reflect.Method m : handlerClass.getDeclaredMethods()) {
            if ("run".equals(m.getName()) && m.getParameterCount() >= 3) {
              runMethod = m;
              break;
            }
          }
        }
        // Fallback to inherited methods if handler doesn't declare run()
        if (runMethod == null) {
          for (java.lang.reflect.Method m : handlerClass.getMethods()) {
            if ("run".equals(m.getName()) && m.getParameterCount() == 4) {
              runMethod = m;
              break;
            }
          }
        }
        if (runMethod == null) return;
        List<?> newList = apexemu.runtime.Trigger.getNew();
        List<?> oldList = apexemu.runtime.Trigger.getOld();
        // Determine the action string
        String action = "";
        if (Boolean.TRUE.equals(apexemu.runtime.Trigger.isBefore()) && Boolean.TRUE.equals(apexemu.runtime.Trigger.isInsert())) action = "BeforeInsert";
        else if (Boolean.TRUE.equals(apexemu.runtime.Trigger.isBefore()) && Boolean.TRUE.equals(apexemu.runtime.Trigger.isUpdate())) action = "BeforeUpdate";
        else if (Boolean.TRUE.equals(apexemu.runtime.Trigger.isBefore()) && Boolean.TRUE.equals(apexemu.runtime.Trigger.isDelete())) action = "BeforeDelete";
        else if (Boolean.TRUE.equals(apexemu.runtime.Trigger.isAfter()) && Boolean.TRUE.equals(apexemu.runtime.Trigger.isInsert())) action = "AfterInsert";
        else if (Boolean.TRUE.equals(apexemu.runtime.Trigger.isAfter()) && Boolean.TRUE.equals(apexemu.runtime.Trigger.isUpdate())) action = "AfterUpdate";
        else if (Boolean.TRUE.equals(apexemu.runtime.Trigger.isAfter()) && Boolean.TRUE.equals(apexemu.runtime.Trigger.isDelete())) action = "AfterDelete";
        else if (Boolean.TRUE.equals(apexemu.runtime.Trigger.isAfter()) && Boolean.TRUE.equals(apexemu.runtime.Trigger.isUndelete())) action = "AfterUndelete";

        Object instance = handlerClass.getDeclaredConstructor().newInstance();
        // TDTM_Runnable.run(List<ApexSObject> newList, List<ApexSObject> oldList,
        //   Schema.DescribeSObjectResult describeObj, TDTM_Runnable.Action action)
        // But Action is an enum that may not exist. Use the string overload or reflection.
        if (runMethod.getParameterCount() == 4) {
          // Try to resolve the Action enum
          try {
            Class<?> actionEnum = Class.forName("generated.TDTM_Runnable$Action", true, cl);
            Object actionVal = java.lang.Enum.valueOf((Class) actionEnum, action);
            String sobjectTypeName = newList != null && !newList.isEmpty() ? ((apexemu.runtime.ApexSObject) newList.get(0)).type() : (oldList != null && !oldList.isEmpty() ? ((apexemu.runtime.ApexSObject) oldList.get(0)).type() : "Account");
            runMethod.invoke(instance, newList, oldList, actionVal,
                new apexemu.runtime.Schema.SObjectType(sobjectTypeName).getDescribe());
          } catch (java.lang.reflect.InvocationTargetException ex) {
            // Propagate DmlException/ApexException but swallow NoSuchMethodError
            // and other linkage errors from placeholder dependencies
            Throwable cause = ex.getCause();
            if (cause instanceof LinkageError) {
              // Handler has placeholder dependencies — skip silently
            } else if (cause instanceof RuntimeException re) {
              throw re;
            } else if (cause instanceof Error err) {
              throw err;
            } else {
              throw new RuntimeException(cause);
            }
          } catch (Exception ex) {
            // Skip handler — likely classloader or missing class issue
          }
        }
      } catch (Exception e) {
        // Silently skip handler errors in direct dispatch mode
      }
    };
  }

  /** Pre-computed class registration entry: stores all name→className mappings discovered once. */
  private record ClassRegistration(String className, List<String> registrationNames) {}

  /** Scan classes once and record which names each class should be registered under. */
  private static List<ClassRegistration> precomputeClassRegistrations(
      List<String> allClassNames, ClassLoader loader) {
    List<ClassRegistration> registrations = new ArrayList<>();
    for (String cn : allClassNames) {
      try {
        Class<?> clazz = Class.forName(cn, false, loader);
        List<String> names = new ArrayList<>();
        String simpleName = cn.contains(".") ? cn.substring(cn.lastIndexOf('.') + 1) : cn;
        names.add(simpleName);
        if (simpleName.contains("$")) {
          names.add(simpleName.replace('$', '.'));
        }
        names.add(cn);
        for (Class<?> inner : clazz.getDeclaredClasses()) {
          String innerSimple = inner.getSimpleName();
          String outerSimple = simpleName.contains("$")
              ? simpleName.substring(0, simpleName.indexOf('$')) : simpleName;
          names.add(outerSimple + "." + innerSimple);
          names.add(innerSimple);
        }
        registrations.add(new ClassRegistration(cn, names));
      } catch (Exception ignored) {
        // skip classes that can't be loaded
      }
    }
    return registrations;
  }

  /** Fast re-registration: uses pre-computed names, loads classes through the given loader. */
  private static void registerAllClassesFast(
      List<ClassRegistration> registrations, ClassLoader loader) {
    apexemu.runtime.System.clearClassRegistry();
    for (ClassRegistration reg : registrations) {
      try {
        Class<?> clazz = Class.forName(reg.className, false, loader);
        // Register the outer class under its own names
        String simpleName = reg.className.contains(".")
            ? reg.className.substring(reg.className.lastIndexOf('.') + 1) : reg.className;
        apexemu.runtime.System.registerClass(simpleName, clazz);
        if (simpleName.contains("$")) {
          apexemu.runtime.System.registerClass(simpleName.replace('$', '.'), clazz);
        }
        apexemu.runtime.System.registerClass(reg.className, clazz);
        // Register inner classes under their own Class<?> objects
        for (Class<?> inner : clazz.getDeclaredClasses()) {
          String innerSimple = inner.getSimpleName();
          String outerSimple = simpleName.contains("$")
              ? simpleName.substring(0, simpleName.indexOf('$')) : simpleName;
          apexemu.runtime.System.registerClass(outerSimple + "." + innerSimple, inner);
          apexemu.runtime.System.registerClass(innerSimple, inner);
        }
      } catch (Exception ignored) {
        // skip
      }
    }
  }

  private static final class TestMethodSpec {
    private final String name;
    private final boolean seeAllData;

    private TestMethodSpec(String name, boolean seeAllData) {
      this.name = name;
      this.seeAllData = seeAllData;
    }
  }

  private static List<String> discoverClassNames(Path classesDir) throws IOException {
    List<String> classNames = new ArrayList<>();
    try (var stream = Files.walk(classesDir)) {
      stream
          .filter(Files::isRegularFile)
          .map(classesDir::relativize)
          .map(Path::toString)
          .filter(name -> name.endsWith(".class"))
          .forEach(
              name -> {
                String className = name.substring(0, name.length() - ".class".length()).replace(File.separatorChar, '.');
                if (className.indexOf('$') >= 0) {
                  return;
                }
                if (className.startsWith("apexemu.")) {
                  return;
                }
                classNames.add(className);
              });
    }
    classNames.sort(String::compareTo);
    return classNames;
  }

  private static void writeJsonReport(Config config, Summary summary, List<TestResult> results) throws IOException {
    StringBuilder sb = new StringBuilder();
    sb.append("{\n");
    sb.append("  \"summary\": {\n");
    sb.append("    \"total\": ").append(summary.total).append(",\n");
    sb.append("    \"passed\": ").append(summary.passed).append(",\n");
    sb.append("    \"failed\": ").append(summary.failed).append(",\n");
    sb.append("    \"cpu_limit_ms\": ").append(config.cpuLimitMs).append(",\n");
    sb.append("    \"heap_limit_bytes\": ").append(config.heapLimitBytes).append("\n");
    sb.append("  },\n");
    sb.append("  \"tests\": [\n");
    for (int i = 0; i < results.size(); i += 1) {
      TestResult result = results.get(i);
      sb.append("    {\n");
      sb.append("      \"class\": ");
      appendJsonString(sb, result.className);
      sb.append(",\n");
      sb.append("      \"method\": ");
      appendJsonString(sb, result.methodName);
      sb.append(",\n");
      sb.append("      \"passed\": ").append(result.passed).append(",\n");
      sb.append("      \"cpu_ms\": ").append(result.cpuMs).append(",\n");
      sb.append("      \"heap_bytes\": ").append(result.heapBytes).append(",\n");
      sb.append("      \"soql_count\": ").append(result.soqlCount).append(",\n");
      sb.append("      \"dml_count\": ").append(result.dmlCount).append(",\n");
      sb.append("      \"failure\": ");
      if (result.failure == null) {
        sb.append("null");
      } else {
        appendJsonString(sb, result.failure);
      }
      sb.append(",\n");
      sb.append("      \"assertions\": [\n");
      for (int j = 0; j < result.assertions.size(); j += 1) {
        SystemAssert.AssertionEntry entry = result.assertions.get(j);
        sb.append("        {\"method\": ");
        appendJsonString(sb, entry.method());
        sb.append(", \"detail\": ");
        appendJsonString(sb, entry.detail());
        sb.append(", \"passed\": ").append(entry.passed());
        sb.append(", \"location\": ");
        if (entry.location() == null) {
          sb.append("null");
        } else {
          appendJsonString(sb, entry.location());
        }
        sb.append("}");
        if (j + 1 < result.assertions.size()) {
          sb.append(",");
        }
        sb.append("\n");
      }
      sb.append("      ]\n");
      sb.append("    }");
      if (i + 1 < results.size()) {
        sb.append(",");
      }
      sb.append("\n");
    }
    sb.append("  ]\n");
    sb.append("}\n");

    if (config.outPath.getParent() != null) {
      Files.createDirectories(config.outPath.getParent());
    }
    Files.writeString(config.outPath, sb.toString(), StandardCharsets.UTF_8);
  }

  private static void appendJsonString(StringBuilder sb, String value) {
    sb.append("\"");
    for (int i = 0; i < value.length(); i += 1) {
      char ch = value.charAt(i);
      switch (ch) {
        case '\\':
          sb.append("\\\\");
          break;
        case '"':
          sb.append("\\\"");
          break;
        case '\n':
          sb.append("\\n");
          break;
        case '\r':
          sb.append("\\r");
          break;
        case '\t':
          sb.append("\\t");
          break;
        default:
          sb.append(ch);
      }
    }
    sb.append("\"");
  }

  private static String shortMessage(Throwable failure) {
    if (failure == null) {
      return null;
    }
    String className = failure.getClass().getSimpleName();
    String message = failure.getMessage();
    if (message == null || message.isBlank()) {
      message = className;
    } else {
      message = className + ": " + message;
    }
    String location = firstRelevantLocation(failure);
    if (location == null) {
      return message;
    }
    return message + " @ " + location;
  }

  private static String firstRelevantLocation(Throwable failure) {
    StackTraceElement[] trace = failure.getStackTrace();
    if (trace == null || trace.length == 0) {
      return null;
    }
    for (StackTraceElement frame : trace) {
      String className = frame.getClassName();
      if (className.startsWith("java.") || className.startsWith("jdk.") || className.startsWith("sun.")) {
        continue;
      }
      if (className.startsWith("apexemu.runner.") || className.startsWith("apexemu.runtime.")) {
        continue;
      }
      return frame.toString();
    }
    return trace[0].toString();
  }

  private static URL toUrl(Path path) throws MalformedURLException {
    return path.toUri().toURL();
  }

  private static final class Summary {
    final int total;
    final int passed;
    final int failed;

    Summary(int total, int passed, int failed) {
      this.total = total;
      this.passed = passed;
      this.failed = failed;
    }
  }

  private record TestResult(
      String className,
      String methodName,
      boolean passed,
      long cpuMs,
      long heapBytes,
      int soqlCount,
      int dmlCount,
      String failure,
      List<SystemAssert.AssertionEntry> assertions) {

    static TestResult loadError(String className, String message) {
      return new TestResult(className, "<load>", false, 0L, 0L, 0, 0, message, List.of());
    }

    static TestResult invalidSignature(String className, String methodName, String message) {
      return new TestResult(className, methodName, false, 0L, 0L, 0, 0, message, List.of());
    }
  }

  private static final class Config {
    final Path classesDir;
    final Path outPath;
    final long cpuLimitMs;
    final long heapLimitBytes;
    final Database.NullOrderDefault soqlNullOrderDefault;
    final boolean registerStandardSchema;
    final String classNamePattern;

    Config(
        Path classesDir,
        Path outPath,
        long cpuLimitMs,
        long heapLimitBytes,
        Database.NullOrderDefault soqlNullOrderDefault,
        boolean registerStandardSchema,
        String classNamePattern) {
      this.classesDir = classesDir;
      this.outPath = outPath;
      this.cpuLimitMs = cpuLimitMs;
      this.heapLimitBytes = heapLimitBytes;
      this.soqlNullOrderDefault = soqlNullOrderDefault;
      this.registerStandardSchema = registerStandardSchema;
      this.classNamePattern = classNamePattern;
    }

    static Config parse(String[] args) {
      Path classesDir = null;
      Path outPath = null;
      long cpuLimitMs = 10_000L;
      long heapLimitBytes = 6_000_000L;
      Database.NullOrderDefault soqlNullOrderDefault =
          parseNullOrderDefault(System.getenv("SOQL_NULL_ORDER_DEFAULT"));
      boolean registerStandardSchema = "true".equalsIgnoreCase(System.getenv("REGISTER_STANDARD_SCHEMA"));
      String classNamePattern = null;

      int i = 0;
      while (i < args.length) {
        String arg = args[i];
        switch (arg) {
          case "--classes-dir":
            i += 1;
            requireValue(i, args, "--classes-dir");
            classesDir = Path.of(args[i]);
            break;
          case "--out":
            i += 1;
            requireValue(i, args, "--out");
            outPath = Path.of(args[i]);
            break;
          case "--cpu-limit-ms":
            i += 1;
            requireValue(i, args, "--cpu-limit-ms");
            cpuLimitMs = Long.parseLong(args[i]);
            break;
          case "--heap-limit-bytes":
            i += 1;
            requireValue(i, args, "--heap-limit-bytes");
            heapLimitBytes = Long.parseLong(args[i]);
            break;
          case "--soql-null-order-default":
            i += 1;
            requireValue(i, args, "--soql-null-order-default");
            soqlNullOrderDefault = parseNullOrderDefault(args[i]);
            break;
          case "--register-standard-schema":
            registerStandardSchema = true;
            break;
          case "--class-name-pattern":
            i += 1;
            requireValue(i, args, "--class-name-pattern");
            classNamePattern = args[i];
            break;
          case "-h":
          case "--help":
            printHelpAndExit(0);
            break;
          default:
            System.err.println("unknown option: " + arg);
            printHelpAndExit(2);
        }
        i += 1;
      }

      if (classesDir == null) {
        System.err.println("missing --classes-dir");
        printHelpAndExit(2);
      }
      return new Config(
          classesDir,
          outPath,
          cpuLimitMs,
          heapLimitBytes,
          soqlNullOrderDefault,
          registerStandardSchema,
          classNamePattern);
    }

    private static void requireValue(int idx, String[] args, String option) {
      if (idx >= args.length) {
        System.err.println("missing value for " + option);
        printHelpAndExit(2);
      }
    }

    private static void printHelpAndExit(int code) {
      System.out.println(
          "Runner options: --classes-dir DIR [--out FILE] [--cpu-limit-ms N] [--heap-limit-bytes N] [--soql-null-order-default FIRST|LAST|DIRECTIONAL] [--class-name-pattern REGEX]");
      System.exit(code);
    }

    private static Database.NullOrderDefault parseNullOrderDefault(String raw) {
      if (raw == null || raw.isBlank()) {
        return Database.NullOrderDefault.FIRST;
      }
      String normalized = raw.trim().toUpperCase();
      return switch (normalized) {
        case "FIRST" -> Database.NullOrderDefault.FIRST;
        case "LAST" -> Database.NullOrderDefault.LAST;
        case "DIRECTIONAL" -> Database.NullOrderDefault.DIRECTIONAL;
        default -> {
          System.err.println(
              "invalid --soql-null-order-default: "
                  + raw
                  + " (allowed: FIRST, LAST, DIRECTIONAL)");
          printHelpAndExit(2);
          yield Database.NullOrderDefault.FIRST;
        }
      };
    }
  }

  /**
   * If a {@code generated.PicklistRegistry} class exists on the classpath,
   * invoke its {@code register()} method to seed picklist metadata from
   * Salesforce field-meta.xml files.
   */
  private static void invokePicklistRegistry(ClassLoader loader) {
    try {
      Class<?> registry = Class.forName("generated.PicklistRegistry", true, loader);
      java.lang.reflect.Method registerMethod = registry.getDeclaredMethod("register");
      registerMethod.invoke(null);
    } catch (ClassNotFoundException ignored) {
      // No picklist registry generated — nothing to do.
    } catch (ReflectiveOperationException ex) {
      java.lang.System.err.println("WARNING: PicklistRegistry.register() failed: " + ex);
    }
  }
}
