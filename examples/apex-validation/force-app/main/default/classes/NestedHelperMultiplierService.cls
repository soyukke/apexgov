public with sharing class NestedHelperMultiplierService {
    public static void run(List<Account> records) {
        Integer n = records.size();
        if (n > 50) return;

        for (Integer i = 0; i < n; i++) {
            applyFourTimes(records[i]);
        }
    }

    private static void applyFourTimes(Account record) {
        for (Integer j = 0; j < 4; j++) {
            applyOne(record);
        }
    }

    private static void applyOne(Account record) {
        update record;
    }
}
