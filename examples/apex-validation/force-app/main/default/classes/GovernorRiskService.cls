public with sharing class GovernorRiskService {
    public static void run(List<Account> records) {
        for (Account accountRow : records) {
            List<Contact> contacts = [SELECT Id, LastName FROM Contact WHERE AccountId = :accountRow.Id LIMIT 50];

            insert new Task(
                Subject = 'Created per account',
                WhatId = accountRow.Id
            );

            for (Contact contactRow : contacts) {
                String payload = '';
                payload += 'Contact: ' + contactRow.LastName;
                String serialized = JSON.serialize(contactRow);
                Contact duplicateRow = contactRow.clone(true, true, false, false);
                Map<String, Object> scratch = new Map<String, Object>();
                scratch.put('payload', serialized);
                scratch.put('dup', duplicateRow);
            }
        }
    }
}
