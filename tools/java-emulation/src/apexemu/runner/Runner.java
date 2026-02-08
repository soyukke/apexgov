package apexemu.runner;

import apexemu.annotations.Test;
import apexemu.runtime.Async;
import apexemu.runtime.Database;
import apexemu.runtime.Limits;
import apexemu.runtime.Limits.Snapshot;
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

public final class Runner {
  public static void main(String[] args) throws Exception {
    Config config = Config.parse(args);
    int exitCode = run(config);
    System.exit(exitCode);
  }

  private static int run(Config config) throws Exception {
    List<String> classNames = discoverClassNames(config.classesDir);
    URLClassLoader loader = new URLClassLoader(new URL[] {toUrl(config.classesDir)});
    List<TestResult> results = new ArrayList<>();

    for (String className : classNames) {
      Class<?> klass;
      try {
        klass = Class.forName(className, true, loader);
      } catch (Throwable error) {
        results.add(TestResult.loadError(className, shortMessage(error)));
        continue;
      }

      Method[] methods = klass.getDeclaredMethods();
      Arrays.sort(methods, Comparator.comparing(Method::getName));
      for (Method method : methods) {
        if (!method.isAnnotationPresent(Test.class)) {
          continue;
        }
        results.add(runTest(config, klass, method));
      }
    }

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

  private static TestResult runTest(Config config, Class<?> klass, Method method) {
    if (method.getParameterCount() != 0) {
      return TestResult.invalidSignature(
          klass.getName(), method.getName(), "@Test methods must have zero arguments");
    }

    Object target = null;
    Throwable failure = null;
    long cpuMs;
    long heapBytes;
    int soqlCount;
    int dmlCount;

    Async.reset();
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();
    Database.clearTriggerHandlers();
    Limits.reset();
    Limits.configure(config.cpuLimitMs, config.heapLimitBytes);

    try {
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

    return new TestResult(
        klass.getName(), method.getName(), failure == null, cpuMs, heapBytes, soqlCount, dmlCount, shortMessage(failure));
  }

  private static void printResult(TestResult result) {
    String state = result.passed ? "PASS" : "FAIL";
    System.out.printf(
        "[%s] %s#%s cpu=%dms heap=%dB soql=%d dml=%d%n",
        state, result.className, result.methodName, result.cpuMs, result.heapBytes, result.soqlCount, result.dmlCount);
    if (!result.passed && result.failure != null && !result.failure.isBlank()) {
      System.out.println("      " + result.failure);
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
        sb.append("null\n");
      } else {
        appendJsonString(sb, result.failure);
        sb.append("\n");
      }
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
      String failure) {

    static TestResult loadError(String className, String message) {
      return new TestResult(className, "<load>", false, 0L, 0L, 0, 0, message);
    }

    static TestResult invalidSignature(String className, String methodName, String message) {
      return new TestResult(className, methodName, false, 0L, 0L, 0, 0, message);
    }
  }

  private static final class Config {
    final Path classesDir;
    final Path outPath;
    final long cpuLimitMs;
    final long heapLimitBytes;

    Config(Path classesDir, Path outPath, long cpuLimitMs, long heapLimitBytes) {
      this.classesDir = classesDir;
      this.outPath = outPath;
      this.cpuLimitMs = cpuLimitMs;
      this.heapLimitBytes = heapLimitBytes;
    }

    static Config parse(String[] args) {
      Path classesDir = null;
      Path outPath = null;
      long cpuLimitMs = 10_000L;
      long heapLimitBytes = 6_000_000L;

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
      return new Config(classesDir, outPath, cpuLimitMs, heapLimitBytes);
    }

    private static void requireValue(int idx, String[] args, String option) {
      if (idx >= args.length) {
        System.err.println("missing value for " + option);
        printHelpAndExit(2);
      }
    }

    private static void printHelpAndExit(int code) {
      System.out.println(
          "Runner options: --classes-dir DIR [--out FILE] [--cpu-limit-ms N] [--heap-limit-bytes N]");
      System.exit(code);
    }
  }
}
