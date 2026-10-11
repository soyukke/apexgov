public with sharing class ExceededGuardService {
    public static void stillRisky(List<Account> records) {
        Integer n = records.size();
        if (n > 200) return;

        for (Integer i = 0; i < n; i++) {
            List<Account> one = [SELECT Id FROM Account WHERE Id = :records[i].Id LIMIT 1];
            if (!one.isEmpty()) {
                records[i].Name = one[0].Name;
            }
        }
    }
}
