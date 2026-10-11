public with sharing class GuardedLoopService {
    public static void safeButFragile(List<Account> records) {
        Integer n = records.size();
        if (n > 120) return;

        for (Integer i = 0; i < n; i++) {
            update records[i];
        }
    }
}
