public with sharing class TranspileInstanceofService {
    public static Boolean isAccount(SObject record) {
        return record instanceof Account;
    }

    public static Boolean isNumeric(Object value) {
        return value instanceof Integer;
    }
}
