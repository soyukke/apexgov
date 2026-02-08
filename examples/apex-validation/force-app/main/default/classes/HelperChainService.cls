public with sharing class HelperChainService {
    public static void run(List<Account> records) {
        Integer n = records.size();
        if (n > 90) return;

        for (Integer i = 0; i < n; i++) {
            applyUpdate(records[i]);
        }
    }

    private static void applyUpdate(Account record) {
        touch(record);
    }

    private static void touch(Account record) {
        update record;
    }
}
