public with sharing class CrossFileCallerService {
    public static void run(List<Account> records) {
        Integer n = records.size();
        if (n > 110) return;

        for (Integer i = 0; i < n; i++) {
            CrossFileDmlHelper.apply(records[i]);
        }
    }
}
