public with sharing class TranspileInstanceofService {
    public static Boolean isAccount(SObject record) {
        return record instanceof Account;
    }

    public static Boolean isNumeric(Object value) {
        return value instanceof Integer;
    }

    public static Boolean isNotContact(SObject record) {
        return !(record instanceof Contact);
    }

    public static Boolean isLeadOrCase(SObject record) {
        return record instanceof Lead || record instanceof Case;
    }

    public static Boolean isAnySObject(Object value) {
        return value instanceof SObject;
    }

    public static Boolean isCustomClass(Object value) {
        return value instanceof CustomService;
    }
}
