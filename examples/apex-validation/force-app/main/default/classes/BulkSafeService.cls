public with sharing class BulkSafeService {
    public static void process(List<Account> records) {
        if (records == null || records.isEmpty()) {
            return;
        }

        Set<Id> accountIds = new Set<Id>();
        for (Account accountRow : records) {
            accountIds.add(accountRow.Id);
        }

        Map<Id, Account> accountMap = new Map<Id, Account>([
            SELECT Id, Name
            FROM Account
            WHERE Id IN :accountIds
        ]);

        List<Task> tasksToInsert = new List<Task>();
        for (Account accountRow : records) {
            if (accountMap.containsKey(accountRow.Id)) {
                tasksToInsert.add(new Task(
                    Subject = 'Bulk processed',
                    WhatId = accountRow.Id
                ));
            }
        }

        if (!tasksToInsert.isEmpty()) {
            insert tasksToInsert;
        }
    }
}
