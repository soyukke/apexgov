public with sharing class DoWhileRiskService {
    public static void run(List<Account> records) {
        Integer n = records.size();
        if (n > 120) return;

        Integer i = 0;
        do
        {
            update records[i];
            i += 1;
        } while (i < n);
    }
}
