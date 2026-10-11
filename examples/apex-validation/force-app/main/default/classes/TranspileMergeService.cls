public with sharing class TranspileMergeService {
    public static void mergeFirstDuplicate(Account masterAccount, List<Account> duplicateAccounts) {
        if (masterAccount == null || duplicateAccounts == null || duplicateAccounts.isEmpty()) {
            return;
        }
        merge masterAccount duplicateAccounts[0];
    }

    public static void mergeFromHelperCalls(List<Account> records) {
        if (records == null || records.size() < 3) {
            return;
        }
        merge pickMaster(records, 0) pickDuplicate(records, 1);
        merge pickMaster(records, 0), pickDuplicate(records, 1), pickDuplicate(records, 2);
    }

    private static Account pickMaster(List<Account> records, Integer index) {
        return records[index];
    }

    private static Account pickDuplicate(List<Account> records, Integer index) {
        return records[index];
    }
}
