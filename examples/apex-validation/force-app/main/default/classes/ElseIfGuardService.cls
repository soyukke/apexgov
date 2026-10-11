public with sharing class ElseIfGuardService {
    public static void run(List<Account> records, Boolean bypass) {
        Integer n = records.size();
        if (bypass) {
            return;
        } else if (n > 140) return;

        for (Integer i = 0; i < n; i++) {
            update records[i];
        }
    }
}
