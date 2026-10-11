public with sharing class TranspileMapConstructorService {
    public static Map<Id, Account> buildFromList(List<Account> records) {
        return new Map<Id, Account>(records);
    }

    public static Map<Id, Account> copyMap(Map<Id, Account> existingMap) {
        return new Map<Id, Account>(existingMap);
    }
}
