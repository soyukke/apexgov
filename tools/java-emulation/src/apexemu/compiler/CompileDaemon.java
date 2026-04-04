package apexemu.compiler;

import javax.tools.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/**
 * In-process compile daemon that avoids JVM startup cost per javac invocation.
 * Reads newline-delimited JSON commands from stdin, compiles using
 * javax.tools.JavaCompiler, and writes JSON results to stdout.
 *
 * Protocol (one JSON object per line):
 *   Request:  {"files":["a.java","b.java"],"classpath":"...","outputDir":"...","sourcepath":"..."}
 *   Response: {"success":true,"errorFiles":[],"errors":""}
 *             {"success":false,"errorFiles":["a.java"],"errors":"a.java:3: error: ..."}
 *   Quit:     {"quit":true}
 */
public final class CompileDaemon {
    public static void main(String[] args) throws Exception {
        JavaCompiler compiler = ToolProvider.getSystemJavaCompiler();
        if (compiler == null) {
            System.err.println("No system Java compiler available");
            System.exit(1);
        }

        BufferedReader reader = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        PrintWriter writer = new PrintWriter(new BufferedWriter(new OutputStreamWriter(System.out, StandardCharsets.UTF_8)), true);
        String line;
        while ((line = reader.readLine()) != null) {
            line = line.trim();
            if (line.isEmpty()) continue;

            if (line.contains("\"quit\"")) {
                writer.println("{\"quit\":true}");
                writer.flush();
                break;
            }

            String[] files = extractJsonArray(line, "files");
            String classpath = extractJsonString(line, "classpath");
            String outputDir = extractJsonString(line, "outputDir");
            String sourcepath = extractJsonString(line, "sourcepath");

            if (files == null || files.length == 0) {
                writer.println("{\"success\":false,\"errorFiles\":[],\"errors\":\"no files specified\"}");
                continue;
            }

            List<String> options = new ArrayList<>();
            if (classpath != null && !classpath.isEmpty()) {
                options.add("-cp");
                options.add(classpath);
            }
            if (outputDir != null && !outputDir.isEmpty()) {
                options.add("-d");
                options.add(outputDir);
            }
            if (sourcepath != null && !sourcepath.isEmpty()) {
                options.add("-sourcepath");
                options.add(sourcepath);
            }
            options.add("-Xmaxerrs");
            options.add("9999");

            DiagnosticCollector<JavaFileObject> diagnostics = new DiagnosticCollector<>();

            try (StandardJavaFileManager fileManager = compiler.getStandardFileManager(diagnostics, null, StandardCharsets.UTF_8)) {
                Iterable<? extends JavaFileObject> compilationUnits =
                    fileManager.getJavaFileObjects(files);

                JavaCompiler.CompilationTask task = compiler.getTask(
                    null, fileManager, diagnostics, options, null, compilationUnits);

                boolean success = task.call();

                Set<String> errorFiles = new LinkedHashSet<>();
                for (Diagnostic<? extends JavaFileObject> d : diagnostics.getDiagnostics()) {
                    if (d.getKind() == Diagnostic.Kind.ERROR) {
                        JavaFileObject source = d.getSource();
                        if (source != null) {
                            errorFiles.add(source.getName());
                        }
                    }
                }

                StringBuilder sb = new StringBuilder();
                sb.append("{\"success\":").append(success);
                sb.append(",\"errorFiles\":[");
                int i = 0;
                for (String ef : errorFiles) {
                    if (i > 0) sb.append(",");
                    sb.append("\"").append(escapeJson(ef)).append("\"");
                    i++;
                }
                sb.append("]}");
                writer.println(sb.toString());
            } catch (Exception e) {
                writer.println("{\"success\":false,\"errorFiles\":[],\"errors\":\"" +
                    escapeJson(e.getMessage()) + "\"}");
            }
            writer.flush();
        }
    }

    private static String escapeJson(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\n", "\\n")
                .replace("\r", "\\r")
                .replace("\t", "\\t");
    }

    // Minimal JSON array extraction: finds "key":["val1","val2",...]
    private static String[] extractJsonArray(String json, String key) {
        String search = "\"" + key + "\":[";
        int start = json.indexOf(search);
        if (start < 0) return null;
        start += search.length();
        int end = json.indexOf("]", start);
        if (end < 0) return null;
        String content = json.substring(start, end);
        if (content.trim().isEmpty()) return new String[0];
        List<String> result = new ArrayList<>();
        int pos = 0;
        while (pos < content.length()) {
            int q1 = content.indexOf('"', pos);
            if (q1 < 0) break;
            int q2 = content.indexOf('"', q1 + 1);
            if (q2 < 0) break;
            result.add(content.substring(q1 + 1, q2));
            pos = q2 + 1;
        }
        return result.toArray(new String[0]);
    }

    // Minimal JSON string extraction: finds "key":"value"
    private static String extractJsonString(String json, String key) {
        String search = "\"" + key + "\":\"";
        int start = json.indexOf(search);
        if (start < 0) return null;
        start += search.length();
        int end = json.indexOf("\"", start);
        if (end < 0) return null;
        return json.substring(start, end);
    }
}
