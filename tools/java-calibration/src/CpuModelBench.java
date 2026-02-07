import java.util.Arrays;

public final class CpuModelBench {
    private static final int DATA_SIZE = 4096;
    private static final int WARMUP_ROUNDS = 4;
    private static final int MEASURE_ROUNDS = 9;
    private static final Row[] ROWS = new Row[DATA_SIZE];
    private static volatile long sink;

    private static final class Row {
        final int id;
        final String name;
        final int score;
        final int[] payload;

        Row(int id, String name, int score, int[] payload) {
            this.id = id;
            this.name = name;
            this.score = score;
            this.payload = payload;
        }

        Row copy() {
            int[] cloned = new int[4];
            System.arraycopy(payload, 0, cloned, 0, cloned.length);
            return new Row(id, name, score, cloned);
        }
    }

    @FunctionalInterface
    private interface Op {
        long run(int iterations);
    }

    private static final class Result {
        final String name;
        final long nsPerIter;
        final long medianRunNs;

        Result(String name, long nsPerIter, long medianRunNs) {
            this.name = name;
            this.nsPerIter = nsPerIter;
            this.medianRunNs = medianRunNs;
        }
    }

    static {
        for (int i = 0; i < DATA_SIZE; i++) {
            int[] payload = new int[16];
            for (int j = 0; j < payload.length; j++) {
                payload[j] = (i * 31 + j * 17) & 1023;
            }
            ROWS[i] = new Row(i, "Name" + i, (i * 13) & 255, payload);
        }
    }

    public static void main(String[] args) {
        int iterations = 50_000;
        if (args.length > 0) {
            iterations = Integer.parseInt(args[0]);
        }

        Result baseline = bench("baseline", CpuModelBench::baselineOp, iterations);
        Result soql = bench("soql", CpuModelBench::soqlLikeOp, iterations);
        Result dml = bench("dml", CpuModelBench::dmlLikeOp, iterations);
        Result json = bench("json", CpuModelBench::jsonLikeOp, iterations);
        Result clone = bench("clone", CpuModelBench::cloneLikeOp, iterations);

        System.out.println("op,ns_per_iter,median_run_ms");
        printResult(baseline);
        printResult(soql);
        printResult(dml);
        printResult(json);
        printResult(clone);
    }

    private static void printResult(Result result) {
        double medianMs = result.medianRunNs / 1_000_000.0;
        System.out.printf("%s,%d,%.3f%n", result.name, result.nsPerIter, medianMs);
    }

    private static Result bench(String name, Op op, int iterations) {
        for (int i = 0; i < WARMUP_ROUNDS; i++) {
            sink ^= op.run(iterations);
        }

        long[] runNs = new long[MEASURE_ROUNDS];
        long totalNs = 0L;
        for (int i = 0; i < MEASURE_ROUNDS; i++) {
            long start = System.nanoTime();
            sink ^= op.run(iterations);
            long elapsed = System.nanoTime() - start;
            runNs[i] = elapsed;
            totalNs += elapsed;
        }

        Arrays.sort(runNs);
        long median = runNs[runNs.length / 2];
        long nsPerIter = Math.max(1L, totalNs / (long) MEASURE_ROUNDS / iterations);
        return new Result(name, nsPerIter, median);
    }

    private static long baselineOp(int iterations) {
        long acc = 0L;
        for (int i = 0; i < iterations; i++) {
            int v = i * 31 + 7;
            acc += (v ^ (v >>> 3)) & 255;
        }
        return acc;
    }

    private static long soqlLikeOp(int iterations) {
        long acc = 0L;
        for (int i = 0; i < iterations; i++) {
            int start = (i * 17) & (DATA_SIZE - 1);
            int matches = 0;
            for (int j = 0; j < 12; j++) {
                Row row = ROWS[(start + j * 17) & (DATA_SIZE - 1)];
                int signal = row.payload[(i + j) & 15];
                if ((signal & 3) == 0) {
                    Row materialized = new Row(row.id, row.name, row.score, row.payload);
                    acc += materialized.id;
                    acc += signal;
                    matches++;
                }
                if (matches > 3) {
                    acc += row.name.hashCode() & 255;
                }
            }
        }
        return acc;
    }

    private static long dmlLikeOp(int iterations) {
        long acc = 0L;
        for (int i = 0; i < iterations; i++) {
            Row row = ROWS[(i * 7) & (DATA_SIZE - 1)];
            int hash = 17;
            for (int j = 0; j < 4; j++) {
                hash = hash * 31 + row.payload[(i + j) & 15];
            }
            hash = hash * 31 + row.id + row.score;
            acc += hash;
        }
        return acc;
    }

    private static long jsonLikeOp(int iterations) {
        long acc = 0L;
        StringBuilder sb = new StringBuilder(128);
        for (int i = 0; i < iterations; i++) {
            Row row = ROWS[(i * 13) & (DATA_SIZE - 1)];
            sb.setLength(0);
            sb.append('{');
            sb.append("\"id\":").append(row.id).append(',');
            sb.append("\"name\":\"").append(row.name).append("\",");
            sb.append("\"score\":").append(row.score).append('}');
            acc += sb.length();
        }
        return acc;
    }

    private static long cloneLikeOp(int iterations) {
        long acc = 0L;
        for (int i = 0; i < iterations; i++) {
            Row row = ROWS[(i * 29) & (DATA_SIZE - 1)];
            Row copy = row.copy();
            acc += copy.payload[0];
            acc += copy.payload[copy.payload.length - 1];
        }
        return acc;
    }
}
