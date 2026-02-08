public with sharing class SameArityOverloadService {
    public static void run(List<Contact> records) {
        Integer n = records.size();
        if (n > 120) return;

        for (Integer i = 0; i < n; i++) {
            touch(new Contact());
        }
    }

    private static void touch(Account acc) {
        acc.Name = acc.Name;
    }

    private static void touch(Contact con) {
        update con;
    }
}
